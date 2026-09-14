#!/usr/bin/env python3
"""Render the dev-eks action-time contract into an isolated source copy.

The renderer deliberately uses only the Python standard library. It never
reads SecretString values; the Terraform contract contains only metadata and
Secret ARNs, while the nine values below are supplied by the approved operator
flow at action time.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NoReturn
from urllib.parse import urlsplit


TOKENS = (
    "__ACTION_TIME_VPC_ID__",
    "__ACTION_TIME_PUBLIC_SUBNET_IDS__",
    "__ACTION_TIME_ACM_CERTIFICATE_ARN__",
    "__ACTION_TIME_BACKEND_HOSTNAME__",
    "__ACTION_TIME_BACKEND_ORIGIN__",
    "__ACTION_TIME_ECR_BACKEND_IMAGE_DIGEST__",
    "__ACTION_TIME_FRONTEND_ORIGIN__",
    "__ACTION_TIME_PROFILE_IMAGE_BUCKET__",
    "__ACTION_TIME_PROFILE_IMAGE_PUBLIC_BASE_URL__",
)
TOKEN_SET = set(TOKENS)
# These three base ConfigMap markers are intentionally replaced by the
# dev-eks overlay patch. They must not be added to the action-time input
# contract and must never survive an applied Kustomize render.
LEGACY_BASE_TOKENS = {
    "__ACTION_TIME_DATABASE_HOST__",
    "__ACTION_TIME_DATABASE_NAME__",
    "__ACTION_TIME_REDIS_HOST__",
}
TOKEN_PATTERN = re.compile(r"__ACTION_TIME_[A-Za-z0-9_]+__")
TEXT_SUFFIXES = {".yaml", ".yml", ".json", ".md", ".sh", ".py", ".txt"}


class RenderError(ValueError):
    """Raised for malformed or incomplete action-time input."""


def fail(message: str) -> "NoReturn":
    raise RenderError(message)


def load_object(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid {label}: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def require_string(values: dict, key: str) -> str:
    value = values.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{key} must be a non-empty string")
    return value.strip()


def validate_origin(value: str, key: str) -> str:
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        fail(f"{key} must be an https origin without path, query or fragment")
    if parsed.username or parsed.password or parsed.port:
        fail(f"{key} must not contain credentials or an explicit port")
    return f"https://{parsed.hostname}" if parsed.hostname else fail(f"{key} has no hostname")


def validate_hostname(value: str) -> str:
    if len(value) > 253 or value != value.lower() or value.endswith("."):
        fail("backend_hostname must be a lowercase DNS hostname")
    labels = value.split(".")
    if len(labels) < 2 or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in labels):
        fail("backend_hostname is not a valid lowercase DNS hostname")
    return value


def validate_trusted_ecr_repository(contract: dict) -> str:
    account = require_string(contract, "aws_account_id")
    if not re.fullmatch(r"[0-9]{12}", account):
        fail("aws_account_id must be a 12-digit account identifier")
    region = require_string(contract, "aws_region")
    if region != "ap-northeast-2":
        fail("aws_region must be ap-northeast-2 for the dev-eks contract")
    repository_url = require_string(contract, "backend_ecr_repository_url")
    match = re.fullmatch(
        r"(?P<account>[0-9]{12})\.dkr\.ecr\.(?P<region>[a-z0-9-]+)\.amazonaws\.com/"
        r"(?P<repository>[a-z0-9](?:[a-z0-9._/-]*[a-z0-9])?)",
        repository_url,
    )
    if not match or len(match.group("repository")) > 256:
        fail("backend_ecr_repository_url must be a valid private ECR repository URL")
    if ".." in match.group("repository") or "//" in match.group("repository"):
        fail("backend_ecr_repository_url must not contain empty repository path segments")
    if match.group("account") != account:
        fail("backend_ecr_repository_url account does not match aws_account_id")
    if match.group("region") != region:
        fail("backend_ecr_repository_url region does not match aws_region")
    return repository_url


def validate_values(inputs: dict, contract: dict) -> dict[str, str]:
    vpc_id = require_string(inputs, "vpc_id")
    if not re.fullmatch(r"vpc-[0-9a-f]+", vpc_id):
        fail("vpc_id must be a lowercase VPC identifier")

    subnets = inputs.get("public_subnet_ids")
    if not isinstance(subnets, list) or len(subnets) < 2 or any(not isinstance(item, str) or not re.fullmatch(r"subnet-[0-9a-f]+", item) for item in subnets):
        fail("public_subnet_ids must contain at least two lowercase subnet identifiers")

    certificate = require_string(inputs, "api_certificate_arn")
    if not re.fullmatch(r"arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/[0-9a-f-]+", certificate):
        fail("api_certificate_arn must be an ACM certificate ARN")

    hostname = validate_hostname(require_string(inputs, "backend_hostname"))
    expected_backend_origin = f"https://{hostname}"
    backend_origin = validate_origin(require_string(inputs, "backend_origin"), "backend_origin")
    if backend_origin != expected_backend_origin:
        fail("backend_origin must match https://backend_hostname")

    trusted_repository_url = validate_trusted_ecr_repository(contract)
    image = require_string(inputs, "backend_image")
    image_match = re.fullmatch(r"(?P<repository>.+)@sha256:(?P<digest>[0-9a-f]{64})", image)
    if not image_match:
        fail("backend_image must be a trusted ECR repository URI with a lowercase sha256 digest")
    if image_match.group("repository") != trusted_repository_url:
        fail("backend_image repository must exactly match backend_ecr_repository_url")

    frontend_origin = validate_origin(require_string(inputs, "frontend_origin"), "frontend_origin")
    profile_bucket = require_string(contract, "profile_image_bucket_name")
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", profile_bucket):
        fail("profile_image_bucket_name is not a valid S3 bucket name")
    profile_base_url = validate_origin(require_string(contract, "profile_image_public_base_url"), "profile_image_public_base_url")

    return {
        "__ACTION_TIME_VPC_ID__": vpc_id,
        "__ACTION_TIME_PUBLIC_SUBNET_IDS__": ",".join(subnets),
        "__ACTION_TIME_ACM_CERTIFICATE_ARN__": certificate,
        "__ACTION_TIME_BACKEND_HOSTNAME__": hostname,
        "__ACTION_TIME_BACKEND_ORIGIN__": backend_origin,
        "__ACTION_TIME_ECR_BACKEND_IMAGE_DIGEST__": image,
        "__ACTION_TIME_FRONTEND_ORIGIN__": frontend_origin,
        "__ACTION_TIME_PROFILE_IMAGE_BUCKET__": profile_bucket,
        "__ACTION_TIME_PROFILE_IMAGE_PUBLIC_BASE_URL__": profile_base_url,
    }


def source_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*") if path.is_file() and path.suffix in TEXT_SUFFIXES)


def applied_source_files(root: Path) -> list[Path]:
    candidates = sorted(
        path
        for subtree in (root / "base" / "backend" / "monolith", root / "base" / "platform-eks", root / "base" / "monitoring", root / "overlays" / "dev-eks-monolith")
        if subtree.is_dir()
        for path in subtree.rglob("*")
        if path.is_file() and path.suffix in TEXT_SUFFIXES
    )
    return candidates or source_files(root)


def replace_tokens(source_root: Path, output_root: Path, replacements: dict[str, str]) -> dict[str, int]:
    if source_root.resolve() == output_root.resolve():
        fail("source and output roots must be different isolated paths")
    if not source_root.is_dir():
        fail(f"source root does not exist: {source_root}")
    if output_root.exists():
        fail(f"output root must not already exist: {output_root}")

    shutil.copytree(source_root, output_root, symlinks=False)
    counts = {token: 0 for token in TOKENS}
    unknown: set[str] = set()
    applied_paths = set(applied_source_files(output_root))
    for path in source_files(output_root):
        text = path.read_text(encoding="utf-8")
        found = TOKEN_PATTERN.findall(text)
        if path not in applied_paths:
            continue
        unknown.update(item for item in found if item not in TOKEN_SET and item not in LEGACY_BASE_TOKENS)
        for token in TOKENS:
            counts[token] += text.count(token)
        rendered = text
        for token, value in replacements.items():
            rendered = rendered.replace(token, value)
        path.write_text(rendered, encoding="utf-8")

    if unknown:
        fail(f"unknown action-time token(s): {', '.join(sorted(unknown))}")
    missing = [token for token, count in counts.items() if count == 0]
    if missing:
        fail(f"required action-time token(s) not present: {', '.join(missing)}")
    return counts


def render_root(kubectl: str, root: Path) -> bytes:
    result = subprocess.run([kubectl, "kustomize", str(root)], capture_output=True, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        fail(f"kustomize render failed for {root.name or root}: {detail}")
    return result.stdout


def assert_rendered_clean(rendered: bytes, root_name: str) -> None:
    decoded = rendered.decode("utf-8", errors="replace")
    remaining = sorted(set(TOKEN_PATTERN.findall(decoded)))
    if "__ACTION_TIME_" in decoded:
        if not remaining:
            remaining = ["<malformed __ACTION_TIME_ marker>"]
        fail(f"unknown or remaining action-time token(s) in {root_name}: {', '.join(remaining)}")


def render(source_root: Path, output_root: Path, inputs: dict, contract: dict, kubectl: str) -> dict:
    replacements = validate_values(inputs, contract)
    counts = replace_tokens(source_root, output_root, replacements)
    roots = {
        "aggregate": output_root / "overlays" / "dev-eks-monolith",
        "platform": output_root / "overlays" / "dev-eks-monolith" / "platform",
        "workload": output_root / "overlays" / "dev-eks-monolith" / "workload",
    }
    rendered = {name: render_root(kubectl, root) for name, root in roots.items()}
    for name, payload in rendered.items():
        assert_rendered_clean(payload, name)
    return {
        "schema_version": "dev-eks-render-result/v1",
        "render_sha256": hashlib.sha256(rendered["aggregate"]).hexdigest(),
        "stage_render_sha256": {name: hashlib.sha256(value).hexdigest() for name, value in rendered.items()},
        "replacement_counts": counts,
        "output_root": str(output_root),
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--kubectl", default="kubectl")
    parser.add_argument("--summary", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        result = render(
            args.source_root,
            args.output_root,
            load_object(args.inputs, "action-time inputs"),
            load_object(args.contract, "deployment contract"),
            args.kubectl,
        )
    except (OSError, RenderError, subprocess.SubprocessError) as exc:
        print(f"render-action-time: {exc}", file=sys.stderr)
        return 2
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "output_root"}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
