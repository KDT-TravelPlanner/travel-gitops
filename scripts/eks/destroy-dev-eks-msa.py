#!/usr/bin/env python3
"""SCRUM-81: review, clean up the MSA Ingress through SSM, then destroy dev-eks."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import sys
import time

SPEC = importlib.util.spec_from_file_location(
    "deployment", Path(__file__).with_name("deploy-dev-eks-msa.py")
)
deployment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deployment)
Error = deployment.DeploymentError
SCHEMA = "dev-eks-msa-destroy/v1"


def write_json(path, value):
    deployment.secure_write(path, json.dumps(value, indent=2) + "\n")


def validate_destroy(plan):
    """Unknown actions and replacement plans must fail closed."""
    deleted = []
    if plan.get("errored") or plan.get("complete") is False:
        raise Error("Terraform destroy plan is errored or incomplete")
    for item in plan.get("resource_changes", []):
        actions = item.get("change", {}).get("actions")
        allowed = (["delete"], ["no-op"])
        if item.get("mode") == "data":
            allowed += (["read"],)
        if actions not in allowed:
            raise Error(f"non-destroy action: {item.get('address')}: {actions}")
        if item.get("mode", "managed") == "managed" and actions == ["delete"]:
            deleted.append(item["address"])
    return sorted(deleted)


def state_identity(state):
    if not isinstance(state.get("resources"), list) or not state.get("lineage"):
        raise Error("invalid Terraform state")
    return {"lineage": state["lineage"], "serial": state["serial"]}


def initialize(args, backend):
    config = deployment.parse_backend(backend)
    if config["key"] != "dev-eks/terraform.tfstate" or config["region"] != args.region:
        raise Error("only dev-eks/terraform.tfstate in the selected region is allowed")
    deployment.terraform(args, "init", "-reconfigure", "-input=false",
                         f"-backend-config={backend.resolve()}")
    if deployment.terraform(args, "workspace", "show").strip() != "default":
        raise Error("only the default Terraform workspace is allowed")
    return config


def read_state(args):
    # Do not persist the raw state: it can include passwords.
    return json.loads(deployment.terraform(args, "state", "pull"))


def cleanup_script(cluster, region, account):
    """Use a private kubeconfig and refuse other Ingress/LB owners cluster-wide."""
    return "\n".join([
        "set -euo pipefail", "umask 077",
        'work=$(mktemp -d /var/tmp/msa-destroy.XXXXXXXX)',
        'trap \'rm -rf "$work"\' EXIT',
        'export KUBECONFIG="$work/kubeconfig"',
        f"test \"$(aws sts get-caller-identity --query Account --output text)\" = {shlex.quote(account)}",
        f"aws eks update-kubeconfig --name {shlex.quote(cluster)} --region {shlex.quote(region)} >/dev/null",
        'kubectl get ingress -A -o json > "$work/ingress.json"',
        'kubectl get service -A -o json > "$work/services.json"',
        "python3 - \"$work\" <<'PY'",
        "import json, pathlib, sys",
        "p = pathlib.Path(sys.argv[1])",
        "for i in json.loads((p/'ingress.json').read_text())['items']:",
        "    m = i['metadata']",
        "    if (m['namespace'], m['name']) != ('travel-planner', 'msa'):",
        "        raise SystemExit('unexpected Ingress owner; resolve separately')",
        "for i in json.loads((p/'services.json').read_text())['items']:",
        "    if i['spec'].get('type') == 'LoadBalancer':",
        "        raise SystemExit('unexpected LoadBalancer Service; resolve separately')",
        "PY",
        "kubectl delete ingress msa -n travel-planner --ignore-not-found --wait=true --timeout=600s",
        "kubectl get targetgroupbindings.elbv2.k8s.aws -A -o json | python3 -c "
        + shlex.quote("import json,sys; d=json.load(sys.stdin); sys.exit('TargetGroupBindings remain') if d['items'] else None"),
    ]) + "\n"


def owned_elb_resources(args, cluster):
    """Read live ELBv2 inventories, including target groups, without deleting AWS resources."""
    found = []
    for command, key, arn_key in (
        ("describe-load-balancers", "LoadBalancers", "LoadBalancerArn"),
        ("describe-target-groups", "TargetGroups", "TargetGroupArn"),
    ):
        items = json.loads(deployment.aws(args, "elbv2", command))[key]
        for item in items:
            arn = item[arn_key]
            response = json.loads(deployment.aws(args, "elbv2", "describe-tags", "--resource-arns", arn))
            tags = {t["Key"]: t["Value"] for t in response["TagDescriptions"][0]["Tags"]}
            if tags.get("elbv2.k8s.aws/cluster") == cluster or tags.get(f"kubernetes.io/cluster/{cluster}") in ("owned", "shared"):
                found.append(arn)
    return sorted(found)


def plan(args):
    directory = args.artifact_dir.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    directory.chmod(0o700)
    identity = deployment.caller_identity(args)
    backend = args.backend_config.resolve()
    config = initialize(args, backend)
    before = state_identity(read_state(args))
    outputs = json.loads(deployment.terraform(args, "output", "-json"))
    cluster = deployment.output_value(outputs, "cluster_name")
    bastion = deployment.output_value(outputs, "bastion_instance_id")
    cluster_info = json.loads(deployment.aws(args, "eks", "describe-cluster", "--name", cluster))["cluster"]
    expected_arn = f"arn:aws:eks:{args.region}:{args.expected_account_id}:cluster/{cluster}"
    if cluster_info["arn"] != expected_arn:
        raise Error("cluster ARN differs from the selected target")
    plan_file = directory / "dev-eks-destroy.tfplan"
    deployment.terraform(args, "plan", "-destroy", "-input=false", f"-out={plan_file}",
                         output=directory / "terraform-plan.log")
    plan_file.chmod(0o600)
    data = json.loads(deployment.terraform(args, "show", "-json", str(plan_file)))
    write_json(directory / "dev-eks-destroy.tfplan.json", data)
    addresses = validate_destroy(data)
    if not addresses:
        raise Error("nothing to destroy")
    if before != state_identity(read_state(args)):
        raise Error("state changed during planning; use a new artifact directory")
    script = directory / "cleanup.sh"
    deployment.secure_write(script, cleanup_script(cluster, args.region, args.expected_account_id))
    review = {
        "schema_version": SCHEMA,
        "account_id": identity["Account"], "region": args.region,
        "terraform_root": str(deployment.TF_ROOT),
        "backend_file": str(backend), "backend_sha256": deployment.sha256(backend),
        "backend": config, "state": before,
        "cluster": cluster, "cluster_arn": expected_arn, "bastion": bastion,
        "plan_sha256": deployment.sha256(plan_file),
        "cleanup_sha256": deployment.sha256(script), "delete_addresses": addresses,
        "owned_elb_resources": owned_elb_resources(args, cluster),
    }
    review_file = directory / "review.json"
    write_json(review_file, review)
    print(json.dumps({"review_file": str(review_file),
                      "review_sha256": deployment.sha256(review_file),
                      "plan_sha256": review["plan_sha256"],
                      "delete_count": len(addresses)}, indent=2))


def remote_cleanup(args, review, script, directory):
    deployment.wait_for_ssm(args, review["bastion"])
    sent = json.loads(deployment.aws(
        args, "ssm", "send-command", "--instance-ids", review["bastion"],
        "--document-name", "AWS-RunShellScript", "--comment", "SCRUM-81 MSA teardown",
        "--parameters", json.dumps({"commands": ["bash -c " + shlex.quote(script.read_text())],
                                     "executionTimeout": ["900"]})))
    write_json(directory / "ssm-command.json", sent)
    command_id = sent["Command"]["CommandId"]
    deadline = time.monotonic() + 1020
    while time.monotonic() < deadline:
        response = json.loads(deployment.aws(args, "ssm", "list-command-invocations",
                                            "--command-id", command_id, "--details"))
        write_json(directory / "ssm-cleanup.json", response)
        invocations = response["CommandInvocations"]
        if invocations:
            status = invocations[0]["Status"]
            if status == "Success":
                return
            if status not in ("Pending", "InProgress", "Delayed", "Cancelling"):
                raise Error(f"SSM cleanup failed: {status}; Terraform was not applied")
        time.sleep(10)
    raise Error("SSM cleanup timed out; inspect the saved command ID before retrying")


def apply(args):
    review_file = args.review_file.resolve()
    if deployment.sha256(review_file) != args.confirm_review_sha256:
        raise Error("review SHA-256 mismatch")
    review = json.loads(review_file.read_text())
    if (review["schema_version"], review["account_id"], review["region"], review["terraform_root"]) != (
        SCHEMA, args.expected_account_id, args.region, str(deployment.TF_ROOT)
    ):
        raise Error("review target mismatch")
    directory = review_file.parent
    plan_file, script = directory / "dev-eks-destroy.tfplan", directory / "cleanup.sh"
    if deployment.sha256(plan_file) != review["plan_sha256"] or review["plan_sha256"] != args.confirm_plan_sha256:
        raise Error("plan SHA-256 mismatch")
    if deployment.sha256(script) != review["cleanup_sha256"]:
        raise Error("cleanup script SHA-256 mismatch")
    backend = Path(review["backend_file"])
    if deployment.sha256(backend) != review["backend_sha256"]:
        raise Error("backend SHA-256 mismatch")
    deployment.caller_identity(args)
    if initialize(args, backend) != review["backend"]:
        raise Error("backend configuration changed")
    if state_identity(read_state(args)) != review["state"]:
        raise Error("state changed since review; generate a new plan")
    data = json.loads(deployment.terraform(args, "show", "-json", str(plan_file)))
    if validate_destroy(data) != review["delete_addresses"]:
        raise Error("saved plan deletion scope differs from review")
    evidence = directory / "apply-evidence"
    evidence.mkdir(mode=0o700, exist_ok=False)
    remote_cleanup(args, review, script, evidence)
    deadline = time.monotonic() + 300
    while True:
        remaining = owned_elb_resources(args, review["cluster"])
        write_json(evidence / "elb-after-cleanup.json", remaining)
        if not remaining or time.monotonic() >= deadline:
            break
        print("waiting for cluster-owned ALB/target groups to disappear", file=sys.stderr)
        time.sleep(10)
    if remaining:
        raise Error("cluster-owned ALB/target groups remain; Terraform was not applied")
    # The controller stays running until its external resources have disappeared.
    deployment.terraform(args, "apply", "-input=false", str(plan_file),
                         output=evidence / "terraform-apply.log")
    state = read_state(args)
    managed = [r["type"] + "." + r["name"] for r in state["resources"]
               if r.get("mode", "managed") == "managed" and r.get("instances")]
    write_json(evidence / "post-state.json", {**state_identity(state), "managed_resources": managed})
    if managed:
        raise Error("managed Terraform instances remain")
    post_plan = evidence / "post-destroy.tfplan"
    deployment.terraform(args, "plan", "-destroy", "-input=false", f"-out={post_plan}",
                         output=evidence / "post-destroy-plan.log")
    post = json.loads(deployment.terraform(args, "show", "-json", str(post_plan)))
    write_json(evidence / "post-destroy.tfplan.json", post)
    if validate_destroy(post):
        raise Error("post-destroy plan still contains deletions")
    remaining = owned_elb_resources(args, review["cluster"])
    write_json(evidence / "elb-after-destroy.json", remaining)
    if remaining:
        raise Error("cluster-owned ELB resources remain after destroy")
    write_json(evidence / "result.json", {"status": "success", "managed_instances": 0})
    print(f"destroy verified; evidence: {evidence}")


def parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--profile", required=True)
    common.add_argument("--region", default="ap-northeast-2")
    common.add_argument("--expected-account-id", required=True)
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest="action", required=True)
    prepare = sub.add_parser("plan", parents=[common])
    prepare.add_argument("--backend-config", type=Path, default=deployment.TF_ROOT / "backend.hcl")
    prepare.add_argument("--artifact-dir", type=Path, required=True)
    execute = sub.add_parser("apply", parents=[common])
    execute.add_argument("--review-file", type=Path, required=True)
    execute.add_argument("--confirm-review-sha256", required=True)
    execute.add_argument("--confirm-plan-sha256", required=True)
    return root


def main():
    os.umask(0o077)
    args = parser().parse_args()
    args.env = {k: v for k, v in os.environ.items()
                if not k.startswith("TF_CLI_ARGS") and k not in ("TF_WORKSPACE", "TF_DATA_DIR")}
    args.env.update(AWS_PROFILE=args.profile, AWS_REGION=args.region, AWS_DEFAULT_REGION=args.region,
                    AWS_PAGER="", TF_WORKSPACE="default")
    try:
        plan(args) if args.action == "plan" else apply(args)
    except (Error, KeyError, ValueError, OSError) as exc:
        print(f"dev-eks-msa-destroy: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
