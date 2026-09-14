#!/usr/bin/env python3
"""Argo CD 전환용: dev-eks overlay의 __ACTION_TIME_*__ placeholder를 Terraform output 값으로 치환한다.

Argo CD는 Git의 kustomize build 결과를 치환 없이 적용하므로, 비밀이 아닌 환경값은
Git에 실제 값으로 커밋한다. Secret 값(DB/Redis 비밀번호, JWT, OAuth, Maps key)은
이 스크립트가 다루지 않으며 Secrets Manager -> <service>-secret 경로를 그대로 쓴다.

사용 예:
  terraform -chdir=infra/environments/dev-eks output -json > /tmp/dev-eks-outputs.json
  python3 scripts/eks/fill-gitops-values.py \
    --terraform-output /tmp/dev-eks-outputs.json \
    --backend-hostname api.kdt-travelplanner.protove.net \
    --frontend-origin https://kdt-travelplanner.protove.net \
    --image community=<ECR URL>@sha256:<digest> --image maps=... --image travel=... \
    [--check]   # 치환 없이 남은 placeholder만 보고 (exit 1 if any)

이미지 digest는 CI PR이 채우는 것이 기본이며 --image 는 수동 보정용이다.
"""
import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TARGETS = ("k8s/overlays/dev-eks",)
# base/platform-eks는 monolith runner가 placeholder를 요구하므로 건드리지 않는다.
# VPC ID는 overlays/dev-eks/platform의 패치가 지정한다.
BUILD_ROOTS = ("k8s/overlays/dev-eks/platform", "k8s/overlays/dev-eks/workload")
TOKEN = re.compile(r"__ACTION_TIME_[A-Z0-9_]+__")
SERVICES = ("identity", "community", "maps", "travel")


def output_value(outputs, key):
    if key not in outputs:
        sys.exit(f"terraform output '{key}' is missing")
    return outputs[key]["value"] if isinstance(outputs[key], dict) and "value" in outputs[key] else outputs[key]


def build_replacements(args):
    outputs = json.loads(Path(args.terraform_output).read_text())
    hostname = args.backend_hostname
    if not re.fullmatch(r"[a-z0-9.-]+", hostname):
        sys.exit("backend hostname must be a lowercase DNS hostname")
    subnets = output_value(outputs, "public_subnet_ids")
    if not isinstance(subnets, list) or len(subnets) < 2:
        sys.exit("public_subnet_ids must be a list with at least two subnets")
    rep = {
        "__ACTION_TIME_VPC_ID__": output_value(outputs, "vpc_id"),
        "__ACTION_TIME_PUBLIC_SUBNET_IDS__": ",".join(subnets),
        "__ACTION_TIME_ACM_CERTIFICATE_ARN__": output_value(outputs, "api_certificate_arn"),
        "__ACTION_TIME_ALB_SECURITY_GROUP_ID__": output_value(outputs, "alb_security_group_id"),
        "__ACTION_TIME_REDIS_PRIMARY_ENDPOINT__": output_value(outputs, "redis_primary_endpoint"),
        "__ACTION_TIME_PROFILE_IMAGE_BUCKET__": output_value(outputs, "profile_image_bucket_name"),
        "__ACTION_TIME_PROFILE_IMAGE_PUBLIC_BASE_URL__": output_value(outputs, "profile_image_public_base_url"),
        "__ACTION_TIME_BACKEND_HOSTNAME__": hostname,
        "__ACTION_TIME_BACKEND_ORIGIN__": f"https://{hostname}",
        "__ACTION_TIME_FRONTEND_ORIGIN__": args.frontend_origin.rstrip("/"),
    }
    for item in args.image or []:
        svc, _, ref = item.partition("=")
        if svc not in SERVICES or not re.fullmatch(r"[A-Za-z0-9./_-]+@sha256:[0-9a-f]{64}", ref):
            sys.exit(f"invalid --image '{item}' (expect <service>=<repo>@sha256:<64 hex>)")
        rep[f"__ACTION_TIME_ECR_{svc.upper()}_IMAGE_DIGEST__"] = ref
    for k, v in rep.items():
        if not isinstance(v, str) or not v:
            sys.exit(f"empty value for {k}")
    return rep


def files():
    for target in TARGETS:
        for path in sorted((REPO_ROOT / target).rglob("*")):
            if path.is_file():
                yield path


def remaining():
    """소스 파일과 kustomize build 결과 양쪽에서 남은 placeholder를 찾는다."""
    import shutil
    import subprocess

    found = {}
    for path in files():
        for tok in TOKEN.findall(path.read_text()):
            found.setdefault(tok, set()).add(str(path.relative_to(REPO_ROOT)))
    kustomize = shutil.which("kustomize")
    if kustomize:
        for root in BUILD_ROOTS:
            out = subprocess.run([kustomize, "build", str(REPO_ROOT / root)], capture_output=True, text=True)
            if out.returncode != 0:
                sys.exit(f"kustomize build failed for {root}: {out.stderr.strip()}")
            for tok in TOKEN.findall(out.stdout):
                found.setdefault(tok, set()).add(f"{root} (build)")
    else:
        print("warning: kustomize not found; build-output check skipped", file=sys.stderr)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--terraform-output")
    ap.add_argument("--backend-hostname")
    ap.add_argument("--frontend-origin")
    ap.add_argument("--image", action="append")
    args = ap.parse_args()

    if not args.check:
        if not (args.terraform_output and args.backend_hostname and args.frontend_origin):
            ap.error("--terraform-output, --backend-hostname, --frontend-origin are required unless --check")
        rep = build_replacements(args)
        changed = 0
        for path in files():
            text = path.read_text()
            new = text
            for k, v in rep.items():
                new = new.replace(k, v)
            if new != text:
                path.write_text(new)
                changed += 1
        print(f"updated {changed} file(s)")

    left = remaining()
    if left:
        print("remaining placeholders:", file=sys.stderr)
        for tok in sorted(left):
            print(f"  {tok}: {', '.join(sorted(left[tok]))}", file=sys.stderr)
        return 1
    print("no __ACTION_TIME_ placeholders remain under " + ", ".join(TARGETS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
