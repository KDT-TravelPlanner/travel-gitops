#!/usr/bin/env python3
"""SCRUM-81: render four immutable MSA images into an isolated Kubernetes bundle."""
import importlib.util
import json
import re
import shutil
import hashlib
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "monolith", Path(__file__).with_name("render-monolith-action-time.py")
)
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)
SERVICES = ("identity", "community", "maps", "travel")
RenderError = legacy.RenderError


def validate_values(inputs, contract):
    if contract.get("schema_version") != "dev-eks-deployment-contract/v2":
        raise RenderError("MSA deployment requires contract v2")
    images = inputs.get("service_images", {})
    repos = contract.get("service_ecr_repository_urls", {})
    if set(images) != set(SERVICES) or set(repos) != set(SERVICES):
        raise RenderError("Exactly four service images and repositories are required")
    for field in ("vpc_id", "public_subnet_ids", "api_certificate_arn"):
        if inputs.get(field) != contract.get(field):
            raise RenderError(f"{field} differs from Terraform contract")
    replacements = {}
    for service in SERVICES:
        values = dict(inputs, backend_image=images[service])
        trusted = dict(contract, backend_ecr_repository_url=repos[service])
        validated = legacy.validate_values(values, trusted)
        validated.pop("__ACTION_TIME_ECR_BACKEND_IMAGE_DIGEST__")
        replacements.update(validated)
        replacements[f"__ACTION_TIME_ECR_{service.upper()}_IMAGE_DIGEST__"] = images[
            service
        ]
    redis = legacy.require_string(contract, "redis_primary_endpoint")
    legacy.validate_hostname(redis)
    sg = legacy.require_string(contract, "alb_security_group_id")
    if not re.fullmatch(r"sg-[a-f0-9]+", sg):
        raise RenderError("Invalid ALB security group")
    replacements["__ACTION_TIME_REDIS_PRIMARY_ENDPOINT__"] = redis
    replacements["__ACTION_TIME_ALB_SECURITY_GROUP_ID__"] = sg
    return replacements


def render(source_root, output_root, inputs, contract, kubectl):
    replacements = validate_values(inputs, contract)
    if output_root.exists() or source_root.resolve() == output_root.resolve():
        raise RenderError("Output must be a new isolated directory")
    shutil.copytree(source_root, output_root)
    # The preserved monolith and Kind sources intentionally retain their own inputs.
    for subtree in ("base/platform-eks", "base/monitoring", "overlays/dev-eks"):
        for path in (output_root / subtree).rglob("*"):
            if not path.is_file():
                continue
            text = path.read_text()
            for key, value in replacements.items():
                text = text.replace(key, value)
            path.write_text(text)
    hashes = {}
    for name, relative in [
        ("aggregate", ""),
        ("platform", "platform"),
        ("workload", "workload"),
    ]:
        result = legacy.render_root(
            kubectl, output_root / "overlays/dev-eks" / relative
        )
        legacy.assert_rendered_clean(result, name)
        if b":local" in result or b"action-time-digest-required" in result:
            raise RenderError("Unresolved local image")
        hashes[name] = hashlib.sha256(result).hexdigest()
    return {
        "schema_version": "dev-eks-render-result/v2",
        "render_sha256": hashes["aggregate"],
        "stage_render_sha256": hashes,
        "service_images": inputs["service_images"],
        "output_root": str(output_root),
    }


def main():
    args = legacy.parse_args(sys.argv[1:])
    try:
        result = render(
            args.source_root,
            args.output_root,
            legacy.load_object(args.inputs, "inputs"),
            legacy.load_object(args.contract, "contract"),
            args.kubectl,
        )
    except (ValueError, OSError) as exc:
        print(f"render-msa: {exc}", file=sys.stderr)
        return 2
    if args.summary:
        args.summary.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
