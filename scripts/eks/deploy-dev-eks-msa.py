#!/usr/bin/env python3
"""SCRUM-81 reviewed Terraform + SSM deployment orchestrator.

`plan` is read-only against AWS/Kubernetes and produces immutable local review
artifacts. `apply` requires the exact plan and review SHA-256 values printed by
`plan`, applies only that saved Terraform plan, then runs the existing staged
MSA deployment on the SSM bastion.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time
from urllib.parse import urlparse


SERVICES = ("identity", "community", "maps", "travel")
STAGES = ("prepare", "namespace-secret", "platform", "workload", "ingress-wait")
ROOT = Path(__file__).resolve().parents[2]
TF_ROOT = ROOT / "infra/environments/dev-eks"


class DeploymentError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def secure_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def run(command: list[str], *, env: dict[str, str], output: Path | None = None) -> str:
    print("+ " + shlex.join(command), file=sys.stderr)
    result = subprocess.run(command, text=True, capture_output=True, env=env)
    if output is not None:
        secure_write(output, result.stdout + result.stderr)
    if result.returncode:
        raise DeploymentError(f"command failed ({command[0]}); inspect the local review log")
    return result.stdout


def aws(args: argparse.Namespace, *command: str, output: Path | None = None) -> str:
    return run(
        [
            "aws",
            *command,
            "--profile",
            args.profile,
            "--region",
            args.region,
            "--output",
            "json",
        ],
        env=args.env,
        output=output,
    )


def terraform(args: argparse.Namespace, *command: str, output: Path | None = None) -> str:
    return run(
        ["terraform", f"-chdir={TF_ROOT}", *command], env=args.env, output=output
    )


def parse_backend(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if "=" not in raw or raw.lstrip().startswith("#"):
            continue
        key, value = raw.split("=", 1)
        result[key.strip()] = value.strip().strip('"')
    for required in ("bucket", "key", "region"):
        if not result.get(required):
            raise DeploymentError(f"backend config is missing {required}")
    return result


def caller_identity(args: argparse.Namespace) -> dict:
    identity = json.loads(aws(args, "sts", "get-caller-identity"))
    if identity.get("Account") != args.expected_account_id:
        raise DeploymentError("AWS caller account differs from --expected-account-id")
    return identity


def caller_role_arn(args: argparse.Namespace, identity: dict) -> str:
    arn = identity.get("Arn", "")
    if ":assumed-role/" not in arn:
        raise DeploymentError("AWS caller must be an assumed IAM role")
    role_name = arn.split("/", 2)[1]
    role = json.loads(aws(args, "iam", "get-role", "--role-name", role_name))["Role"]
    role_arn = role.get("Arn", "")
    if not role_arn.startswith(f"arn:aws:iam::{args.expected_account_id}:role/"):
        raise DeploymentError("resolved IAM role belongs to a different account")
    return role_arn


def assert_empty_state(args: argparse.Namespace, bucket: str, key: str, directory: Path) -> dict:
    target = directory / (key.replace("/", "_") + ".json")
    # A missing or unreadable State is not treated as empty.
    aws(args, "s3api", "head-object", "--bucket", bucket, "--key", key)
    aws(args, "s3api", "get-object", "--bucket", bucket, "--key", key, str(target))
    try:
        state = json.loads(target.read_text(encoding="utf-8"))
    finally:
        target.unlink(missing_ok=True)
    resources = state.get("resources")
    if not isinstance(resources, list):
        raise DeploymentError(f"competing State has no resources array: {key}")
    managed = [item for item in resources if item.get("mode", "managed") == "managed"]
    if managed:
        raise DeploymentError(f"competing State is not empty: {key}")
    return {"key": key, "serial": state.get("serial"), "managed_resources": 0}


def latest_images(args: argparse.Namespace) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for service in SERVICES:
        repository = f"{args.project_name}-dev-{service}"
        repo = json.loads(
            aws(args, "ecr", "describe-repositories", "--repository-names", repository)
        )["repositories"][0]
        details = json.loads(
            aws(
                args,
                "ecr",
                "describe-images",
                "--repository-name",
                repository,
                "--filter",
                "tagStatus=TAGGED",
            )
        ).get("imageDetails", [])
        candidates = [item for item in details if item.get("imageDigest") and item.get("imageTags")]
        if not candidates:
            raise DeploymentError(f"no tagged ECR image found for {service}")
        image = max(candidates, key=lambda item: item.get("imagePushedAt", ""))
        digest = image["imageDigest"]
        if not digest.startswith("sha256:") or len(digest) != 71:
            raise DeploymentError(f"invalid ECR digest returned for {service}")
        result[service] = {
            "repository": repository,
            "repository_url": repo["repositoryUri"],
            "digest": digest,
            "image": repo["repositoryUri"] + "@" + digest,
            "tags": sorted(image["imageTags"]),
            "pushed_at": image.get("imagePushedAt"),
        }
    return result


def plan_actions(plan_json: dict) -> dict[str, int]:
    counts = {"create": 0, "update": 0, "delete": 0, "replace": 0, "no-op": 0, "read": 0}
    for change in plan_json.get("resource_changes", []):
        actions = change.get("change", {}).get("actions", [])
        if actions == ["create"]:
            counts["create"] += 1
        elif actions == ["update"]:
            counts["update"] += 1
        elif actions == ["delete"]:
            counts["delete"] += 1
        elif "create" in actions and "delete" in actions:
            counts["replace"] += 1
        elif actions == ["no-op"]:
            counts["no-op"] += 1
        elif actions == ["read"]:
            counts["read"] += 1
    return counts


def validate_origins(args: argparse.Namespace) -> None:
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?", args.backend_hostname):
        raise DeploymentError("backend hostname has an invalid shape")
    backend = urlparse(args.backend_origin)
    frontend = urlparse(args.frontend_origin)
    if backend.scheme != "https" or backend.hostname != args.backend_hostname or backend.path not in ("", "/"):
        raise DeploymentError("backend origin must be the HTTPS origin of backend hostname")
    if frontend.scheme != "https" or not frontend.hostname or frontend.path not in ("", "/"):
        raise DeploymentError("frontend origin must be an HTTPS origin without a path")


def validate_plan_contract(plan_json: dict, caller_arn: str) -> None:
    for item in plan_json.get("resource_changes", []):
        change = item.get("change", {})
        if item.get("type") == "aws_eks_cluster" and "create" in change.get("actions", []):
            access = (change.get("after", {}).get("access_config") or [{}])[0]
            if access.get("bootstrap_cluster_creator_admin_permissions") is not False:
                raise DeploymentError("new clusters must disable automatic creator admin to avoid duplicate Access Entries")
    outputs = plan_json.get("planned_values", {}).get("outputs", {})
    principals = outputs.get("admin_access_entry_principal_arns", {}).get("value", [])
    role_name = caller_arn.split("/", 2)[1] if ":assumed-role/" in caller_arn else ""
    if not role_name or not any(item.endswith("/" + role_name) for item in principals or []):
        raise DeploymentError("current SSO role is not present in planned EKS admin Access Entries")

    node_groups = [
        item.get("change", {}).get("after", {})
        for item in plan_json.get("resource_changes", [])
        if item.get("type") == "aws_eks_node_group"
    ]
    if len(node_groups) != 1:
        raise DeploymentError("plan must contain exactly one EKS managed node group")
    node = node_groups[0]
    scaling = (node.get("scaling_config") or [{}])[0]
    if node.get("instance_types") != ["t3.large"] or scaling != {
        "desired_size": 2,
        "max_size": 4,
        "min_size": 2,
    }:
        raise DeploymentError("planned node capacity differs from reviewed 2/2/4 t3.large baseline")


def plan(args: argparse.Namespace) -> None:
    directory = args.artifact_dir.resolve()
    if directory.exists() and any(directory.iterdir()):
        raise DeploymentError("artifact directory must be empty; preserve the previous failed plan and logs")
    directory.mkdir(parents=True, exist_ok=True)
    directory.chmod(stat.S_IRWXU)
    validate_origins(args)
    identity = caller_identity(args)
    admin_role_arn = caller_role_arn(args, identity)
    backend = parse_backend(args.backend_config)
    if backend["region"] != args.region:
        raise DeploymentError("backend region differs from --region")
    states = [
        assert_empty_state(args, backend["bucket"], key, directory)
        for key in args.inactive_state_key
    ]
    images = latest_images(args)

    run(
        ["terraform", "fmt", "-recursive", "-check", str(ROOT / "infra")],
        env=args.env,
        output=directory / "terraform-fmt.log",
    )
    terraform(
        args,
        "init",
        "-reconfigure",
        "-input=false",
        f"-backend-config={args.backend_config.resolve()}",
        output=directory / "terraform-init.log",
    )
    terraform(args, "validate", output=directory / "terraform-validate.log")
    terraform(args, "test", output=directory / "terraform-test.log")
    imports = discover_admin_imports(args, admin_role_arn)
    secure_write(directory / "access-imports.json", json.dumps(imports, indent=2) + "\n")
    run(
        [sys.executable, "-m", "unittest", "discover", "-s", str(ROOT / "scripts/eks/tests"), "-v"],
        env=args.env,
        output=directory / "msa-tests.log",
    )
    run(
        [sys.executable, "-m", "unittest", "discover", "-s", str(ROOT / "monitoring/tests"), "-v"],
        env=args.env,
        output=directory / "monitoring-tests.log",
    )
    plan_file = directory / "dev-eks.tfplan"
    terraform(
        args,
        "plan",
        "-input=false",
        "-var=admin_principal_arns=" + json.dumps([admin_role_arn]),
        "-var=existing_admin_entry_imports=" + json.dumps(imports["entries"]),
        "-var=existing_admin_policy_imports=" + json.dumps(imports["policies"]),
        f"-out={plan_file}",
        output=directory / "terraform-plan.log",
    )
    plan_json_path = directory / "dev-eks.tfplan.json"
    secure_write(plan_json_path, terraform(args, "show", "-json", str(plan_file)))
    plan_json = json.loads(plan_json_path.read_text(encoding="utf-8"))
    counts = plan_actions(plan_json)
    if counts["delete"] or counts["replace"]:
        raise DeploymentError("Terraform plan contains delete/replace actions")
    validate_plan_contract(plan_json, identity["Arn"])

    review = {
        "schema_version": "dev-eks-msa-review/v1",
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "aws": {
            "account_id": identity["Account"],
            "caller_arn": identity["Arn"],
            "admin_principal_arn": admin_role_arn,
            "region": args.region,
        },
        "terraform": {
            "root": str(TF_ROOT),
            "plan_file": str(plan_file),
            "plan_sha256": sha256(plan_file),
            "actions": counts,
            "competing_states": states,
            "access_imports": imports,
        },
        "deployment_inputs": {
            "backend_hostname": args.backend_hostname,
            "backend_origin": args.backend_origin,
            "frontend_origin": args.frontend_origin,
            "images": images,
        },
    }
    review_path = directory / "review.json"
    secure_write(review_path, json.dumps(review, indent=2, ensure_ascii=False) + "\n")
    review_sha = sha256(review_path)
    print(json.dumps({"status": "review-required", "review_file": str(review_path), "review_sha256": review_sha, "plan_sha256": review["terraform"]["plan_sha256"], "actions": counts, "images": {s: images[s]["image"] for s in SERVICES}}, indent=2))


def state_resources(module: dict):
    yield from module.get("resources", [])
    for child in module.get("child_modules", []):
        yield from state_resources(child)


def discover_admin_imports(args: argparse.Namespace, principal: str) -> dict:
    """Read existing state and EKS; never import or modify state during plan."""
    state = json.loads(terraform(args, "show", "-json"))
    resources = list(state_resources(state.get("values", {}).get("root_module", {})))
    by_address = {item["address"]: item for item in resources}
    cluster = by_address.get("module.eks_cluster.aws_eks_cluster.this")
    result = {"entries": {}, "policies": {}}
    if cluster is None:
        return result
    name = cluster["values"]["name"]
    entries = json.loads(aws(args, "eks", "list-access-entries", "--cluster-name", name))["accessEntries"]
    if principal not in entries:
        return result
    entry = json.loads(aws(args, "eks", "describe-access-entry", "--cluster-name", name,
                           "--principal-arn", principal))["accessEntry"]
    if entry.get("type") != "STANDARD" or entry.get("principalArn") != principal:
        raise DeploymentError("existing admin entry does not match STANDARD principal contract")
    suffix = "[" + json.dumps(principal) + "]"
    if "module.eks_cluster.aws_eks_access_entry.admin" + suffix not in by_address:
        result["entries"][principal] = name + ":" + principal
    policies = json.loads(aws(args, "eks", "list-associated-access-policies", "--cluster-name", name,
                              "--principal-arn", principal))["associatedAccessPolicies"]
    policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    for policy in policies:
        if policy["policyArn"] == policy_arn:
            if policy.get("accessScope", {}).get("type") != "cluster":
                raise DeploymentError("existing admin policy is not cluster-scoped; review manually")
            if "module.eks_cluster.aws_eks_access_policy_association.admin" + suffix not in by_address:
                result["policies"][principal] = "#".join([name, principal, policy_arn])
    return result


def output_value(outputs: dict, name: str):
    try:
        return outputs[name]["value"]
    except (KeyError, TypeError) as exc:
        raise DeploymentError(f"required Terraform output is missing: {name}") from exc


def wait_for_ssm(args: argparse.Namespace, instance_id: str) -> None:
    for _ in range(40):
        response = json.loads(
            aws(
                args,
                "ssm",
                "describe-instance-information",
                "--filters",
                f"Key=InstanceIds,Values={instance_id}",
            )
        )
        items = response.get("InstanceInformationList", [])
        if len(items) == 1 and items[0].get("PingStatus") == "Online":
            return
        time.sleep(15)
    raise DeploymentError("SSM bastion did not become Online")


def ssm_stage(args: argparse.Namespace, outputs: dict, values_key: str, values_sha: str, stage: str, evidence_dir: Path) -> None:
    bucket = output_value(outputs, "monitoring_config_bucket_name")
    prefix = output_value(outputs, "monitoring_bundle_prefix")
    launcher = "/var/tmp/travel-planner-dev-eks-msa-launcher"
    work_dir = "/var/tmp/travel-planner-dev-eks-msa"
    commands = [
        "set -eu",
        f"install -d -m 700 {shlex.quote(launcher)}",
        f"aws s3 cp {shlex.quote(f's3://{bucket}/{prefix}/scripts/eks/run-dev-eks-deployment.sh')} {shlex.quote(launcher + '/run-dev-eks-deployment.sh')} --only-show-errors",
        f"aws s3 cp {shlex.quote(f's3://{bucket}/{prefix}/scripts/eks/msa-runner.sh')} {shlex.quote(launcher + '/msa-runner.sh')} --only-show-errors",
        f"chmod 700 {shlex.quote(launcher + '/run-dev-eks-deployment.sh')} {shlex.quote(launcher + '/msa-runner.sh')}",
        " ".join(
            shlex.quote(item)
            for item in [
                "bash", launcher + "/run-dev-eks-deployment.sh",
                "--stage", stage,
                "--bucket", bucket,
                "--bundle-prefix", prefix,
                "--contract-key", output_value(outputs, "deployment_contract_s3_key"),
                "--values-s3-key", values_key,
                "--expected-bundle-revision", output_value(outputs, "monitoring_bundle_revision"),
                "--expected-contract-sha256", output_value(outputs, "deployment_contract_sha256"),
                "--expected-values-sha256", values_sha,
                "--expected-account-id", args.expected_account_id,
                "--expected-region", args.region,
                "--work-dir", work_dir,
            ]
        ),
    ]
    sent = json.loads(
        aws(
            args,
            "ssm",
            "send-command",
            "--instance-ids", output_value(outputs, "bastion_instance_id"),
            "--document-name", "AWS-RunShellScript",
            "--comment", f"SCRUM-81 MSA stage {stage}",
            "--parameters", json.dumps({"commands": commands, "executionTimeout": ["14400"]}),
        )
    )
    command_id = sent["Command"]["CommandId"]
    wait_for_stage(args, command_id, output_value(outputs, "bastion_instance_id"),
                   stage, evidence_dir)
    print(f"stage={stage} status=success")


def wait_for_stage(args, command_id, instance_id, stage, evidence_dir, timeout=14520):
    """Wait for the submitted command; never resubmit on local timeout."""
    evidence = evidence_dir / f"ssm-{stage}.json"
    secure_write(evidence, json.dumps({"CommandId": command_id, "InstanceId": instance_id,
                                      "Status": "Pending"}) + "\n")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        # List tolerates SSM's eventual visibility: an empty list means wait.
        result = json.loads(aws(args, "ssm", "list-command-invocations",
                                "--command-id", command_id, "--instance-id", instance_id,
                                "--details"))
        items = result.get("CommandInvocations", [])
        if items:
            invocation = items[0]
            secure_write(evidence, json.dumps(invocation, indent=2) + "\n")
            status = invocation.get("Status")
            if status == "Success":
                return invocation
            if status in {"Failed", "TimedOut", "Cancelled"}:
                raise DeploymentError(f"SSM stage failed: {stage}; status={status}; command_id={command_id}")
            if status not in {"Pending", "InProgress", "Delayed", "Cancelling"}:
                raise DeploymentError(f"SSM status unknown; inspect command_id={command_id} before retry")
        time.sleep(10)
    raise DeploymentError(
        f"SSM local wait expired: {stage}; remote status is unresolved; "
        f"inspect command_id={command_id}; do not resubmit the deployment"
    )


def apply(args: argparse.Namespace) -> None:
    review_path = args.review_file.resolve()
    if sha256(review_path) != args.confirm_review_sha256:
        raise DeploymentError("review SHA-256 differs from explicit confirmation")
    review = json.loads(review_path.read_text(encoding="utf-8"))
    plan_file = Path(review["terraform"]["plan_file"])
    plan_sha = sha256(plan_file)
    if plan_sha != review["terraform"]["plan_sha256"] or plan_sha != args.confirm_plan_sha256:
        raise DeploymentError("saved Terraform plan differs from explicit confirmation")
    if review["aws"]["account_id"] != args.expected_account_id or review["aws"]["region"] != args.region:
        raise DeploymentError("review AWS target differs from apply target")
    identity = caller_identity(args)
    if caller_role_arn(args, identity) != review["aws"]["admin_principal_arn"]:
        raise DeploymentError("current IAM role differs from the reviewed admin principal")
    if review["terraform"]["actions"].get("delete") or review["terraform"]["actions"].get("replace"):
        raise DeploymentError("review contains destructive Terraform actions")

    evidence_dir = review_path.parent / "apply-evidence"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    evidence_dir.chmod(stat.S_IRWXU)
    terraform(args, "apply", "-input=false", "-auto-approve", str(plan_file), output=evidence_dir / "terraform-apply.log")
    outputs = json.loads(terraform(args, "output", "-json"))
    inputs = review["deployment_inputs"]
    values = {
        "vpc_id": output_value(outputs, "vpc_id"),
        "public_subnet_ids": output_value(outputs, "public_subnet_ids"),
        "api_certificate_arn": output_value(outputs, "api_certificate_arn"),
        "backend_hostname": inputs["backend_hostname"],
        "backend_origin": inputs["backend_origin"],
        "frontend_origin": inputs["frontend_origin"],
        "service_images": {service: inputs["images"][service]["image"] for service in SERVICES},
    }
    values_path = evidence_dir / "msa-values.json"
    secure_write(values_path, json.dumps(values, indent=2) + "\n")
    values_sha = sha256(values_path)
    bucket = output_value(outputs, "monitoring_config_bucket_name")
    prefix = output_value(outputs, "monitoring_bundle_prefix")
    values_key = f"{prefix}/action-values/{values_sha}.json"
    aws(args, "s3", "cp", str(values_path), f"s3://{bucket}/{values_key}", "--only-show-errors")

    instance_id = output_value(outputs, "bastion_instance_id")
    wait_for_ssm(args, instance_id)
    stop = STAGES.index(args.through_stage) + 1
    for stage in STAGES[:stop]:
        ssm_stage(args, outputs, values_key, values_sha, stage, evidence_dir)
    print(json.dumps({"status": "success", "through_stage": args.through_stage, "values_sha256": values_sha, "evidence_dir": str(evidence_dir)}, indent=2))


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--profile", default="kdt-travel-admin")
    common.add_argument("--region", default="ap-northeast-2")
    common.add_argument("--expected-account-id", required=True)
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest="action", required=True)
    prepare = sub.add_parser("plan", parents=[common], help="produce review artifacts without applying")
    prepare.add_argument("--backend-config", type=Path, default=TF_ROOT / "backend.hcl")
    prepare.add_argument("--artifact-dir", type=Path, required=True)
    prepare.add_argument("--project-name", default="kdt-travelplanner")
    prepare.add_argument("--inactive-state-key", action="append", default=[])
    prepare.add_argument("--backend-hostname", required=True)
    prepare.add_argument("--backend-origin", required=True)
    prepare.add_argument("--frontend-origin", required=True)
    execute = sub.add_parser("apply", parents=[common], help="apply an exactly reviewed plan and deploy through SSM")
    execute.add_argument("--review-file", type=Path, required=True)
    execute.add_argument("--confirm-review-sha256", required=True)
    execute.add_argument("--confirm-plan-sha256", required=True)
    execute.add_argument("--through-stage", choices=STAGES, default="ingress-wait")
    return root


def main() -> int:
    os.umask(0o077)
    args = parser().parse_args()
    args.env = dict(os.environ, AWS_PROFILE=args.profile, AWS_REGION=args.region)
    if args.action == "plan" and not args.inactive_state_key:
        args.inactive_state_key = ["dev-runtime/terraform.tfstate", "dev-load-test/terraform.tfstate"]
    try:
        plan(args) if args.action == "plan" else apply(args)
    except (DeploymentError, KeyError, ValueError, OSError, json.JSONDecodeError) as exc:
        print(f"dev-eks-msa: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
