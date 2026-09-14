"""SCRUM-81 offline contract and rendered-manifest integration tests."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[3]


def module(name, filename):
    s = importlib.util.spec_from_file_location(name, ROOT / "scripts/eks" / filename)
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


renderer = module("renderer", "render-action-time.py")
runtime = module("runtime", "msa-runtime.py")
orchestrator = module("orchestrator", "deploy-dev-eks-msa.py")


def fixture():
    repos = {
        s: "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/dev-" + s
        for s in runtime.SERVICES
    }
    c = {
        "schema_version": "dev-eks-deployment-contract/v2",
        "aws_account_id": "123456789012",
        "aws_region": "ap-northeast-2",
        "vpc_id": "vpc-1234",
        "public_subnet_ids": ["subnet-1234", "subnet-abcd"],
        "api_certificate_arn": "arn:aws:acm:ap-northeast-2:123456789012:certificate/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        "alb_security_group_id": "sg-1234",
        "profile_image_bucket_name": "example-profile-images",
        "profile_image_public_base_url": "https://images.example.test",
        "redis_primary_endpoint": "primary.redis.example.test",
        "service_ecr_repository_urls": repos,
    }
    v = {k: c[k] for k in ["vpc_id", "public_subnet_ids", "api_certificate_arn"]}
    v.update(
        backend_hostname="api.example.test",
        backend_origin="https://api.example.test",
        frontend_origin="https://example.test",
        service_images={s: r + "@sha256:" + "a" * 64 for s, r in repos.items()},
    )
    return c, v


def build(relative):
    binary = os.environ.get("KUBECTL", "kubectl")
    return list(
        yaml.safe_load_all(
            subprocess.check_output([binary, "kustomize", str(ROOT / relative)])
        )
    )


class ContractTests(unittest.TestCase):
    def test_registry_auth_is_not_forwarded_to_presigned_blob_redirect(self):
        c, v = fixture()

        def inspect_request(req, **kwargs):
            self.assertEqual(req.get_header("Authorization"), "Basic fixture-token")
            redirected = runtime.urllib.request.HTTPRedirectHandler().redirect_request(
                req, None, 307, "Temporary Redirect", {},
                "https://example.s3.amazonaws.com/blob?X-Amz-Signature=fixture",
            )
            self.assertIsNone(redirected.get_header("Authorization"))
            self.assertIsNotNone(redirected.get_header("Accept"))
            raise StopIteration("request verified")

        with patch.object(runtime, "aws", return_value={"authorizationData": [{
            "proxyEndpoint": "https://123456789012.dkr.ecr.ap-northeast-2.amazonaws.com",
            "authorizationToken": "fixture-token",
        }]}), patch.object(runtime.urllib.request, "urlopen", side_effect=inspect_request):
            with self.assertRaises(StopIteration):
                runtime.inspect_images(c, v)

    def test_missing_and_foreign_images_fail_before_copy(self):
        for mutation in ["missing", "foreign", "tag", "region", "network", "schema"]:
            with self.subTest(mutation=mutation):
                c, v = fixture()
                if mutation == "missing":
                    del v["service_images"]["maps"]
                if mutation == "foreign":
                    v["service_images"]["maps"] = v["service_images"]["identity"]
                if mutation == "tag":
                    v["service_images"]["maps"] = (
                        c["service_ecr_repository_urls"]["maps"] + ":latest"
                    )
                if mutation == "region":
                    c["aws_region"] = "us-east-1"
                if mutation == "network":
                    v["vpc_id"] = "vpc-abcd"
                if mutation == "schema":
                    c["schema_version"] = "dev-eks-deployment-contract/v1"
                with self.assertRaises(ValueError):
                    renderer.validate_values(v, c)

    def test_render_all_stages_no_placeholder_and_stable_hash(self):
        c, v = fixture()
        with tempfile.TemporaryDirectory() as t:
            results = [
                renderer.render(
                    ROOT / "k8s",
                    Path(t) / str(i),
                    v,
                    c,
                    os.environ.get("KUBECTL", "kubectl"),
                )
                for i in range(2)
            ]
            self.assertEqual(results[0]["render_sha256"], results[1]["render_sha256"])
            docs = list(
                yaml.safe_load_all(
                    subprocess.check_output(
                        ["kubectl", "kustomize", str(Path(t) / "0/overlays/dev-eks")]
                    )
                )
            )
            apps = [
                d
                for d in docs
                if d["kind"] == "Deployment"
                and d["metadata"].get("namespace") == "travel-planner"
            ]
            self.assertEqual(
                {d["metadata"]["name"] for d in apps}, set(runtime.SERVICES)
            )

    def test_secret_isolation_and_required_keys(self):
        app = {k: "fixture-only" for keys in runtime.KEYS.values() for k in keys}
        items = runtime.secret_payloads(
            app, {"username": "u", "password": "p"}, {"password": "r"}
        )
        for item in items:
            service = item["metadata"]["name"].removesuffix("-secret")
            self.assertEqual(set(item["data"]), set(runtime.KEYS[service]))
        del app["GOOGLE_MAPS_API_KEY"]
        with self.assertRaises(ValueError):
            runtime.secret_payloads(
                app, {"username": "u", "password": "p"}, {"password": "r"}
            )

    def test_arm_image_rejected(self):
        c, v = fixture()

        class Response:
            def __init__(self, data):
                self.data = data

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self):
                return json.dumps(self.data).encode()

        with patch.object(
            runtime,
            "aws",
            return_value={
                "authorizationData": [
                    {
                        "proxyEndpoint": "https://123456789012.dkr.ecr.ap-northeast-2.amazonaws.com",
                        "authorizationToken": "fixture",
                    }
                ]
            },
        ), patch.object(
            runtime.urllib.request,
            "urlopen",
            side_effect=[
                Response({"config": {"digest": "sha256:fixture"}}),
                Response({"os": "linux", "architecture": "arm64"}),
            ],
        ):
            with self.assertRaises(ValueError):
                runtime.inspect_images(c, v)


class OrchestratorTests(unittest.TestCase):
    def test_ssm_pending_and_inprogress_wait_until_success(self):
        responses = [{"CommandInvocations": []}] + [
            {"CommandInvocations": [{"Status": status}]} for status in ["InProgress", "Success"]
        ]
        with tempfile.TemporaryDirectory() as t, patch.object(
            orchestrator, "aws", side_effect=[json.dumps(r) for r in responses]
        ) as aws, patch.object(orchestrator.time, "sleep"):
            result = orchestrator.wait_for_stage(None, "cmd", "instance", "workload", Path(t))
            self.assertEqual(result["Status"], "Success")
            self.assertEqual(aws.call_count, 3)
            self.assertEqual(json.loads((Path(t) / "ssm-workload.json").read_text())["Status"], "Success")

    def test_ssm_terminal_failure_and_local_timeout_are_distinct(self):
        with tempfile.TemporaryDirectory() as t, patch.object(orchestrator, "aws", return_value=json.dumps({
            "CommandInvocations": [{"Status": "Failed"}]
        })):
            with self.assertRaisesRegex(orchestrator.DeploymentError, "status=Failed"):
                orchestrator.wait_for_stage(None, "cmd", "instance", "workload", Path(t))
            with self.assertRaisesRegex(orchestrator.DeploymentError, "remote status is unresolved"):
                orchestrator.wait_for_stage(None, "cmd", "instance", "workload", Path(t), timeout=0)

    def test_new_cluster_bootstrap_admin_is_rejected(self):
        with self.assertRaisesRegex(orchestrator.DeploymentError, "automatic creator admin"):
            orchestrator.validate_plan_contract({"resource_changes": [{
                "type": "aws_eks_cluster", "change": {"actions": ["create"], "after": {
                    "access_config": [{"bootstrap_cluster_creator_admin_permissions": True}]
                }}
            }]}, "unused")

    def test_existing_creator_is_imported_without_state_mutation(self):
        principal = "arn:aws:iam::123456789012:role/Admin"
        policy = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        state = {"values": {"root_module": {"child_modules": [{"resources": [{
            "address": "module.eks_cluster.aws_eks_cluster.this", "values": {"name": "cluster"}
        }]}]}}}
        responses = [
            {"accessEntries": [principal]},
            {"accessEntry": {"principalArn": principal, "type": "STANDARD"}},
            {"associatedAccessPolicies": [{"policyArn": policy, "accessScope": {"type": "cluster"}}]},
        ]
        with patch.object(orchestrator, "terraform", return_value=json.dumps(state)) as tf, patch.object(
            orchestrator, "aws", side_effect=[json.dumps(r) for r in responses]
        ):
            result = orchestrator.discover_admin_imports(None, principal)
        self.assertEqual(result, {"entries": {principal: "cluster:" + principal},
                                  "policies": {principal: "cluster#" + principal + "#" + policy}})
        tf.assert_called_once_with(None, "show", "-json")

    def test_fresh_state_requires_no_import_or_aws_lookup(self):
        with patch.object(orchestrator, "terraform", return_value="{}"), patch.object(orchestrator, "aws") as aws:
            self.assertEqual(orchestrator.discover_admin_imports(None, "arn"), {"entries": {}, "policies": {}})
        aws.assert_not_called()

    def test_unreadable_existing_entries_fail_closed(self):
        state = {"values": {"root_module": {"resources": [{
            "address": "module.eks_cluster.aws_eks_cluster.this", "values": {"name": "cluster"}
        }]}}}
        with patch.object(orchestrator, "terraform", return_value=json.dumps(state)), patch.object(
            orchestrator, "aws", side_effect=orchestrator.DeploymentError("AccessDenied")
        ), self.assertRaises(orchestrator.DeploymentError):
            orchestrator.discover_admin_imports(None, "arn")

    def test_assumed_sso_role_resolves_to_iam_principal(self):
        args = type("Args", (), {"expected_account_id": "123456789012"})()
        identity = {
            "Arn": "arn:aws:sts::123456789012:assumed-role/AdminRole/session"
        }
        with patch.object(
            orchestrator,
            "aws",
            return_value=json.dumps(
                {"Role": {"Arn": "arn:aws:iam::123456789012:role/path/AdminRole"}}
            ),
        ) as mocked:
            self.assertEqual(
                orchestrator.caller_role_arn(args, identity),
                "arn:aws:iam::123456789012:role/path/AdminRole",
            )
        self.assertIn("AdminRole", mocked.call_args.args)

    def test_plan_actions_classifies_replace_as_destructive(self):
        changes = {
            "resource_changes": [
                {"change": {"actions": ["create"]}},
                {"change": {"actions": ["update"]}},
                {"change": {"actions": ["delete", "create"]}},
                {"change": {"actions": ["delete"]}},
                {"change": {"actions": ["no-op"]}},
            ]
        }
        self.assertEqual(
            orchestrator.plan_actions(changes),
            {"create": 1, "update": 1, "delete": 1, "replace": 1, "no-op": 1, "read": 0},
        )

    def test_plan_contract_requires_current_admin_and_capacity(self):
        caller = "arn:aws:sts::123456789012:assumed-role/AdminRole/session"
        plan = {
            "planned_values": {"outputs": {"admin_access_entry_principal_arns": {"value": [
                "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AdminRole"
            ]}}},
            "resource_changes": [{"type": "aws_eks_node_group", "change": {"after": {
                "instance_types": ["t3.large"],
                "scaling_config": [{"desired_size": 2, "max_size": 4, "min_size": 2}],
            }}}],
        }
        orchestrator.validate_plan_contract(plan, caller)
        plan["resource_changes"][0]["change"]["after"]["instance_types"] = ["t3.medium"]
        with self.assertRaises(orchestrator.DeploymentError):
            orchestrator.validate_plan_contract(plan, caller)

    def test_origins_must_be_https_and_match_hostname(self):
        args = type("Args", (), {
            "backend_hostname": "api.example.test",
            "backend_origin": "https://api.example.test",
            "frontend_origin": "https://example.test",
        })()
        orchestrator.validate_origins(args)
        args.backend_origin = "http://api.example.test"
        with self.assertRaises(orchestrator.DeploymentError):
            orchestrator.validate_origins(args)



class WorkloadReplicaTests(unittest.TestCase):
    def check_workload(self, overrides=None, hpa_overrides=None):
        _, values = fixture()
        minimums = {"identity": 1, "travel": 2, "community": 2, "maps": 2}
        def command(args):
            service = args[3]
            if args[2] == "deployment":
                replicas = (overrides or {}).get(service, minimums[service])
                return json.dumps({
                    "metadata": {"generation": 1},
                    "spec": {"replicas": replicas, "template": {"spec": {"containers": [
                        {"name": service, "image": values["service_images"][service]}
                    ]}}},
                    "status": {"observedGeneration": 1, "updatedReplicas": replicas,
                               "readyReplicas": replicas, "availableReplicas": replicas}
                })
            return json.dumps({"spec": {"minReplicas": (hpa_overrides or {}).get(service, minimums[service]), "maxReplicas": 4}})
        with patch.object(runtime, "command", side_effect=command):
            runtime.verify_workload(values)

    def test_minimum_and_scaled_workloads_pass(self):
        self.check_workload()
        self.check_workload({s: 4 for s in runtime.SERVICES})

    def test_below_minimum_above_maximum_and_wrong_hpa_fail(self):
        for service in runtime.SERVICES:
            for replicas in (0 if service == "identity" else 1, 5):
                with self.subTest(service=service, replicas=replicas):
                    with self.assertRaises(ValueError):
                        self.check_workload({service: replicas})
            with self.subTest(service=service, hpa=True):
                with self.assertRaises(ValueError):
                    self.check_workload(hpa_overrides={service: 2 if service == "identity" else 1})

class ManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.docs = build("k8s/overlays/dev-eks")

    def test_four_replicated_apps_with_sidecar_and_secrets(self):
        for service in runtime.SERVICES:
            d = next(
                x
                for x in self.docs
                if x["kind"] == "Deployment" and x["metadata"]["name"] == service
            )
            self.assertEqual(d["spec"]["replicas"], 1 if service == "identity" else 2)
            pod = d["spec"]["template"]
            spec = pod["spec"]
            self.assertEqual(spec["serviceAccountName"], service)
            self.assertEqual(
                {x["name"] for x in spec["containers"]}, {service, "alloy-sidecar"}
            )
            self.assertEqual(
                pod["metadata"]["annotations"]["prometheus.io/port"], "9091"
            )
            app = next(x for x in spec["containers"] if x["name"] == service)
            self.assertEqual(
                {x["valueFrom"]["secretKeyRef"]["name"] for x in app["env"]},
                {service + "-secret"},
            )
            self.assertEqual(
                {x["name"] for x in app["env"]}, set(runtime.KEYS[service])
            )
            self.assertEqual(app["resources"]["requests"], {
                "cpu": "250m", "memory": {"identity": "512Mi", "travel": "896Mi", "community": "1Gi", "maps": "512Mi"}[service]
            })
            self.assertNotIn("nc -z postgres 5432", json.dumps(spec["initContainers"]))
            h = next(
                x
                for x in self.docs
                if x["kind"] == "HorizontalPodAutoscaler"
                and x["metadata"]["name"] == service
            )
            self.assertEqual(h["spec"]["minReplicas"], 1 if service == "identity" else 2)
            self.assertEqual(h["spec"]["maxReplicas"], 4)
            self.assertEqual(h["spec"]["metrics"][0]["containerResource"]["target"]["averageUtilization"], 60)
            self.assertEqual(
                h["spec"]["metrics"][0]["containerResource"]["container"], service
            )

    def test_public_routes_exclude_internal(self):
        i = next(x for x in self.docs if x["kind"] == "Ingress")
        routes = i["spec"]["rules"][0]["http"]["paths"]
        self.assertFalse(any("internal" in p["path"] for p in routes))
        self.assertEqual(
            {p["backend"]["service"]["name"] for p in routes}, set(runtime.SERVICES)
        )

    def test_monitoring_not_scraped_by_every_node(self):
        config = next(
            x
            for x in self.docs
            if x["kind"] == "ConfigMap" and x["metadata"]["name"] == "alloy-config"
        )["data"]["config.alloy"]
        self.assertIn("spec.nodeName=", config)
        self.assertIn('regex = sys.env("NODE_NAME")', config)
        self.assertNotIn('prometheus.scrape "kube_state_metrics"', config)
        common = next(
            x
            for x in self.docs
            if x["kind"] == "Deployment" and x["metadata"]["name"] == "alloy-common"
        )
        self.assertEqual(common["spec"]["replicas"], 1)
        self.assertEqual(common["spec"]["strategy"]["type"], "Recreate")

    def test_monolith_and_kind_service_roots_preserved(self):
        docs = build("k8s/overlays/dev-eks-monolith/load-test")
        self.assertIn(
            "backend",
            {x["metadata"]["name"] for x in docs if x["kind"] == "Deployment"},
        )
        for s in runtime.SERVICES:
            docs = build("k8s/overlays/kind-dev/backend/" + s + "-service")
            d = next(x for x in docs if x["kind"] == "Deployment")
            self.assertEqual(d["spec"]["replicas"], 1)




class RunnerTests(unittest.TestCase):
    def test_unavailable_images_prevent_kubernetes_apply(self):
        with tempfile.TemporaryDirectory() as t:
            script = """set -euo pipefail
source "$1/scripts/eks/msa-runner.sh"
WORK_DIR="$2"; BUNDLE_DIR="$2"; CONTRACT_FILE="$2/contract"; VALUES_FILE="$2/values"; LOG_FILE="$2/log"
require_prepared() { :; }
require_completed_stage() { :; }
python3() { return 1; }
die() { exit 42; }
kubectl_diff_and_apply() { touch "$WORK_DIR/applied"; }
apply_workload
"""
            r = subprocess.run(
                ["bash", "-c", script, "test", str(ROOT), t], capture_output=True
            )
            self.assertEqual(r.returncode, 42)
            self.assertFalse((Path(t) / "applied").exists())

    def test_monolith_action_time_renderer_still_works(self):
        c, v = fixture()
        c["backend_ecr_repository_url"] = c["service_ecr_repository_urls"]["identity"]
        v["backend_image"] = v["service_images"]["identity"]
        with tempfile.TemporaryDirectory() as t:
            result = renderer.legacy.render(
                ROOT / "k8s", Path(t) / "rendered", v, c, "kubectl"
            )
            self.assertEqual(result["schema_version"], "dev-eks-render-result/v1")

if __name__ == "__main__":
    unittest.main()
