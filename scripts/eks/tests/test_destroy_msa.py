"""SCRUM-81 offline teardown safety and orchestration regression tests."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import ExitStack
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "destroy", Path(__file__).resolve().parents[1] / "destroy-dev-eks-msa.py")
destroy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(destroy)


class DestroyTests(unittest.TestCase):
    def apply_fixture(self, directory):
        backend = directory / "backend.hcl"
        backend.write_text("example backend")
        (directory / "cleanup.sh").write_text("exit 0")
        (directory / "dev-eks-destroy.tfplan").write_text("saved plan")
        review = {
            "schema_version": destroy.SCHEMA, "account_id": "123456789012",
            "region": "ap-northeast-2", "terraform_root": str(destroy.deployment.TF_ROOT),
            "backend_file": str(backend), "backend_sha256": destroy.deployment.sha256(backend),
            "backend": {}, "state": {"lineage": "test", "serial": 1},
            "cluster": "test", "bastion": "i-test", "delete_addresses": ["x"],
            "plan_sha256": destroy.deployment.sha256(directory / "dev-eks-destroy.tfplan"),
            "cleanup_sha256": destroy.deployment.sha256(directory / "cleanup.sh"),
        }
        review_file = directory / "review.json"
        destroy.write_json(review_file, review)
        return argparse.Namespace(review_file=review_file,
                                  confirm_review_sha256=destroy.deployment.sha256(review_file),
                                  confirm_plan_sha256=review["plan_sha256"],
                                  expected_account_id=review["account_id"], region=review["region"])

    def test_apply_cleanup_failure_blocks_terraform_and_success_verifies_post_state(self):
        for failure in (True, False):
            with self.subTest(cleanup_failure=failure), tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
                directory = Path(temp)
                args = self.apply_fixture(directory)
                calls = []
                def tf(_args, *command, **kwargs):
                    calls.append(command[0])
                    if command[0] == "show":
                        return json.dumps({"resource_changes": [] if "post-destroy" in command[-1] else [
                            {"address": "x", "change": {"actions": ["delete"]}}]})
                    return ""
                def cleanup(*_args):
                    calls.append("cleanup")
                    if failure:
                        raise destroy.Error("failed")
                stack.enter_context(patch.object(destroy.deployment, "caller_identity"))
                stack.enter_context(patch.object(destroy, "initialize", return_value={}))
                stack.enter_context(patch.object(destroy, "read_state", return_value={
                    "lineage": "test", "serial": 1, "resources": []}))
                stack.enter_context(patch.object(destroy.deployment, "terraform", side_effect=tf))
                stack.enter_context(patch.object(destroy, "remote_cleanup", side_effect=cleanup))
                stack.enter_context(patch.object(destroy, "owned_elb_resources", return_value=[]))
                if failure:
                    with self.assertRaises(destroy.Error):
                        destroy.apply(args)
                    self.assertNotIn("apply", calls)
                    self.assertFalse((directory / "apply-evidence/result.json").exists())
                else:
                    destroy.apply(args)
                    self.assertLess(calls.index("cleanup"), calls.index("apply"))
                    self.assertEqual(calls, ["show", "cleanup", "apply", "plan", "show"])
                    self.assertTrue((directory / "apply-evidence/result.json").exists())

    def test_stale_state_blocks_remote_cleanup(self):
        with tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
            args = self.apply_fixture(Path(temp))
            stack.enter_context(patch.object(destroy.deployment, "caller_identity"))
            stack.enter_context(patch.object(destroy, "initialize", return_value={}))
            stack.enter_context(patch.object(destroy, "read_state", return_value={
                "lineage": "test", "serial": 2, "resources": []}))
            cleanup = stack.enter_context(patch.object(destroy, "remote_cleanup"))
            with self.assertRaises(destroy.Error):
                destroy.apply(args)
            cleanup.assert_not_called()

    def test_only_delete_and_noop_managed_actions(self):
        for actions in (["create"], ["update"], ["delete", "create"], ["read"], [], ["unknown"]):
            with self.subTest(actions=actions), self.assertRaises(destroy.Error):
                destroy.validate_destroy({"resource_changes": [
                    {"address": "x", "mode": "managed", "change": {"actions": actions}}]})
        self.assertEqual(destroy.validate_destroy({"resource_changes": [
            {"address": "x", "change": {"actions": ["delete"]}},
            {"address": "y", "change": {"actions": ["no-op"]}},
            {"address": "z", "mode": "data", "change": {"actions": ["read"]}},
        ]}), ["x"])

    def test_incomplete_or_errored_plan_rejected(self):
        for plan in ({"complete": False}, {"errored": True}):
            with self.assertRaises(destroy.Error):
                destroy.validate_destroy(plan)

    def test_persistent_backend_rejected_before_init(self):
        with tempfile.TemporaryDirectory() as temp:
            backend = Path(temp) / "backend.hcl"
            backend.write_text('bucket="test"\nkey="dev/terraform.tfstate"\nregion="ap-northeast-2"\n')
            with patch.object(destroy.deployment, "terraform") as tf, self.assertRaises(destroy.Error):
                destroy.initialize(argparse.Namespace(region="ap-northeast-2"), backend)
            tf.assert_not_called()

    def test_review_hash_mismatch_prevents_any_aws_call(self):
        with tempfile.TemporaryDirectory() as temp:
            review = Path(temp) / "review.json"
            review.write_text('{}')
            with patch.object(destroy.deployment, "aws") as aws, self.assertRaises(destroy.Error):
                destroy.apply(argparse.Namespace(review_file=review, confirm_review_sha256="wrong"))
            aws.assert_not_called()

    def test_cleanup_shell_valid_and_checks_owners_before_delete(self):
        script = destroy.cleanup_script("test-cluster", "ap-northeast-2", "123456789012")
        result = subprocess.run(["bash", "-n"], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(script.index("unexpected Ingress owner"), script.index("kubectl delete"))
        self.assertLess(script.index("unexpected LoadBalancer Service"), script.index("kubectl delete"))
        self.assertNotIn("--force", script)

    def test_elb_inventory_includes_target_groups_and_excludes_other_clusters(self):
        responses = [
            {"LoadBalancers": [{"LoadBalancerArn": "lb"}]},
            {"TagDescriptions": [{"Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "ours"}]}]},
            {"TargetGroups": [{"TargetGroupArn": "tg"}, {"TargetGroupArn": "other"}]},
            {"TagDescriptions": [{"Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "ours"}]}]},
            {"TagDescriptions": [{"Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "elsewhere"}]}]},
        ]
        with patch.object(destroy.deployment, "aws", side_effect=map(json.dumps, responses)):
            self.assertEqual(destroy.owned_elb_resources(None, "ours"), ["lb", "tg"])

    def test_ssm_failure_is_not_success(self):
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / "cleanup.sh"
            script.write_text("exit 1")
            with patch.object(destroy.deployment, "wait_for_ssm"), patch.object(
                destroy.deployment, "aws", side_effect=[
                    json.dumps({"Command": {"CommandId": "test"}}),
                    json.dumps({"CommandInvocations": [{"Status": "Failed"}]}),
                ]), self.assertRaises(destroy.Error):
                destroy.remote_cleanup(None, {"bastion": "i-test"}, script, Path(temp))
            self.assertTrue((Path(temp) / "ssm-command.json").exists())
            self.assertTrue((Path(temp) / "ssm-cleanup.json").exists())


if __name__ == "__main__":
    unittest.main()
