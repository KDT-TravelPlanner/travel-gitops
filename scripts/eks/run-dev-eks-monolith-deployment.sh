#!/usr/bin/env bash
set -euo pipefail

# This script is executed by SSM Run Command on the private Bastion. It is
# intentionally stage-oriented: each later stage revalidates the prepare
# state, render hash and contract before it can mutate Kubernetes.
umask 077

STAGE=""
BUCKET=""
BUNDLE_PREFIX="kubernetes/monitoring"
CONTRACT_KEY="kubernetes/monitoring/runtime-contract.json"
VALUES_FILE=""
VALUES_S3_KEY=""
EXPECTED_BUNDLE_REVISION=""
EXPECTED_CONTRACT_SHA256=""
EXPECTED_RENDER_SHA256=""
EXPECTED_VALUES_SHA256=""
EXPECTED_ACCOUNT_ID=""
EXPECTED_REGION=""
REDIS_PRIMARY_ENDPOINT=""
WORK_DIR="${DEV_EKS_WORK_DIR:-/var/tmp/travel-planner-dev-eks}"
ROLLOUT_TIMEOUT="${DEV_EKS_ROLLOUT_TIMEOUT:-900s}"
INGRESS_TIMEOUT_SECONDS="${DEV_EKS_INGRESS_TIMEOUT_SECONDS:-900}"

usage() {
  cat >&2 <<'USAGE'
Usage: run-dev-eks-deployment.sh --stage prepare|namespace-secret|platform|workload|ingress-wait \
  --bucket <private-monitoring-bucket> --values-file <non-secret-json> \
  --expected-bundle-revision <sha256> [--expected-render-sha256 <sha256>] \
  [--expected-contract-sha256 <sha256>] \
  [--expected-values-sha256 <sha256>] \
  [--expected-account-id <12 digits>] [--expected-region <region>] \
  [--redis-primary-endpoint <private-tls-endpoint>] \
  [--bundle-prefix <prefix>] [--contract-key <key>] [--work-dir <dir>]
USAGE
}

die() {
  if [[ "${STAGE:-}" == "platform" && -n "${LOG_FILE:-}" && -s "$LOG_FILE" ]]; then
    printf 'platform_log_tail:\n' >&2
    tail -n 120 "$LOG_FILE" >&2 || true
  fi
  printf 'stage=%s status=failed reason=%s\n' "${STAGE:-unknown}" "$1" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --stage) STAGE="${2:?missing value for --stage}"; shift 2 ;;
    --bucket) BUCKET="${2:?missing value for --bucket}"; shift 2 ;;
    --bundle-prefix) BUNDLE_PREFIX="${2:?missing value for --bundle-prefix}"; shift 2 ;;
    --contract-key) CONTRACT_KEY="${2:?missing value for --contract-key}"; shift 2 ;;
    --values-file) VALUES_FILE="${2:?missing value for --values-file}"; shift 2 ;;
    --values-s3-key) VALUES_S3_KEY="${2:?missing value for --values-s3-key}"; shift 2 ;;
    --expected-bundle-revision) EXPECTED_BUNDLE_REVISION="${2:?missing value for --expected-bundle-revision}"; shift 2 ;;
    --expected-contract-sha256) EXPECTED_CONTRACT_SHA256="${2:?missing value for --expected-contract-sha256}"; shift 2 ;;
    --expected-render-sha256) EXPECTED_RENDER_SHA256="${2:?missing value for --expected-render-sha256}"; shift 2 ;;
    --expected-values-sha256) EXPECTED_VALUES_SHA256="${2:?missing value for --expected-values-sha256}"; shift 2 ;;
    --expected-account-id) EXPECTED_ACCOUNT_ID="${2:?missing value for --expected-account-id}"; shift 2 ;;
    --expected-region) EXPECTED_REGION="${2:?missing value for --expected-region}"; shift 2 ;;
    --redis-primary-endpoint) REDIS_PRIMARY_ENDPOINT="${2:?missing value for --redis-primary-endpoint}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:?missing value for --work-dir}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage; die "unknown argument" ;;
  esac
done

[[ "$STAGE" =~ ^(prepare|namespace-secret|platform|workload|ingress-wait)$ ]] || die "invalid stage"
[[ -n "$BUCKET" && -n "$EXPECTED_BUNDLE_REVISION" ]] || die "bucket and bundle revision are required"
[[ -n "$VALUES_FILE" || -n "$VALUES_S3_KEY" ]] || die "values-file or values-s3-key is required"
[[ "$EXPECTED_BUNDLE_REVISION" =~ ^[0-9a-f]{64}$ ]] || die "bundle revision must be a full lowercase sha256"
if [[ -n "$EXPECTED_CONTRACT_SHA256" && ! "$EXPECTED_CONTRACT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  die "contract sha256 must be a full lowercase sha256"
fi
if [[ -n "$EXPECTED_VALUES_SHA256" && ! "$EXPECTED_VALUES_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  die "values sha256 must be a full lowercase sha256"
fi
if [[ -n "$EXPECTED_RENDER_SHA256" && ! "$EXPECTED_RENDER_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  die "render sha256 must be a full lowercase sha256"
fi
if [[ -n "$EXPECTED_ACCOUNT_ID" && ! "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  die "expected account id must be 12 digits"
fi
if [[ -n "$EXPECTED_REGION" && ! "$EXPECTED_REGION" =~ ^[a-z0-9-]+$ ]]; then
  die "expected region has an invalid shape"
fi
if [[ -n "$REDIS_PRIMARY_ENDPOINT" && ! "$REDIS_PRIMARY_ENDPOINT" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
  die "Redis primary endpoint has an invalid shape"
fi

for command_name in aws jq kubectl python3 sha256sum mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command unavailable: $command_name"
done

mkdir -p "$WORK_DIR"
chmod 0700 "$WORK_DIR"
KUBECONFIG_PATH="$WORK_DIR/kubeconfig"
export KUBECONFIG="$KUBECONFIG_PATH"
BUNDLE_DIR="$WORK_DIR/bundle"
RENDER_DIR="$WORK_DIR/rendered"
STATE_FILE="$WORK_DIR/runner-state.json"
CONTRACT_FILE="$WORK_DIR/runtime-contract.json"
SUMMARY_FILE="$WORK_DIR/deployment-summary.json"
LOG_FILE="$WORK_DIR/${STAGE}.log"

cleanup_transient() {
  rm -f -- \
    "$LOG_FILE" \
    "$WORK_DIR/cluster-version.json" \
    "$WORK_DIR/nodes.txt" \
    "$WORK_DIR/render-result.json" \
    "$WORK_DIR/render-summary.json" \
    "$WORK_DIR/revalidated-render-result.json" \
    "$WORK_DIR/revalidated-render-summary.json" \
    "$WORK_DIR/secret-metadata.json" \
    "$WORK_DIR/backend-deployment.json" \
    "$WORK_DIR/backend-hpa.json" \
    "$WORK_DIR/controller-webhook-tls" \
    "$SUMMARY_FILE"
  if [[ -n "$VALUES_S3_KEY" ]]; then
    rm -f -- "$VALUES_FILE"
  fi
}
trap cleanup_transient EXIT
trap 'cleanup_transient; exit 129' HUP
trap 'cleanup_transient; exit 130' INT
trap 'cleanup_transient; exit 143' TERM

load_contract() {
  [[ -s "$CONTRACT_FILE" ]] || die "runtime contract is missing"
  jq -e '
    (.schema_version == "dev-eks-deployment-contract/v1" or .schema_version == "dev-eks-deployment-contract/v2") and
    (.aws_account_id | type == "string" and test("^[0-9]{12}$")) and
    (.aws_region | type == "string" and length > 0) and
    (.cluster_name | type == "string" and length > 0) and
    (.alb_security_group_id | type == "string" and test("^sg-[0-9a-f]+$")) and
    (.bastion_instance_id | type == "string" and length > 0) and
    (.bundle_revision_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.vpc_id | type == "string" and test("^vpc-[0-9a-f]+$")) and
    (.public_subnet_ids | type == "array" and length >= 2) and
    (.api_certificate_arn | type == "string" and startswith("arn:")) and
    (.profile_image_bucket_name | type == "string" and length > 0) and
    (.profile_image_public_base_url | type == "string" and startswith("https://")) and
    (.backend_application_secret_arn | type == "string" and startswith("arn:")) and
    (.database_master_secret_arn | type == "string" and startswith("arn:")) and
    (.redis_auth_secret_arn | type == "string" and startswith("arn:")) and
    (has("SecretString") | not) and (has("SecretBinary") | not)
  ' "$CONTRACT_FILE" >/dev/null || die "runtime contract schema or redaction check failed"
  [[ "$(jq -r '.bundle_revision_sha256' "$CONTRACT_FILE")" == "$EXPECTED_BUNDLE_REVISION" ]] || die "runtime contract bundle revision mismatch"
  if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
    [[ "$(jq -r '.aws_account_id' "$CONTRACT_FILE")" == "$EXPECTED_ACCOUNT_ID" ]] || die "runtime contract account mismatch"
  fi
  if [[ -n "$EXPECTED_REGION" ]]; then
    [[ "$(jq -r '.aws_region' "$CONTRACT_FILE")" == "$EXPECTED_REGION" ]] || die "runtime contract region mismatch"
  fi
}

verify_bundle() {
  local manifest="$BUNDLE_DIR/bundle-manifest.json" calculated_revision
  [[ -s "$manifest" ]] || die "bundle manifest is missing"
  jq -e --arg expected "$EXPECTED_BUNDLE_REVISION" '.schema_version == "dev-eks-bundle/v1" and .revision == $expected' "$manifest" >/dev/null || die "bundle manifest revision mismatch"
  calculated_revision="$(jq -cjS '.files' "$manifest" | sha256sum | awk '{print $1}')"
  [[ "$calculated_revision" == "$EXPECTED_BUNDLE_REVISION" ]] || die "bundle manifest content revision mismatch"
  while IFS=$'\t' read -r relative expected; do
    [[ -n "$relative" && -n "$expected" ]] || die "malformed bundle manifest entry"
    [[ "$relative" != /* && "$relative" != *".."* && "$relative" != *"//"* ]] || die "unsafe bundle manifest path"
    [[ -f "$BUNDLE_DIR/$relative" ]] || die "bundle file is missing"
    actual="$(sha256sum "$BUNDLE_DIR/$relative" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "bundle file checksum mismatch"
  done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' "$manifest")
}

download_bundle_and_contract() {
  rm -rf -- "$BUNDLE_DIR" "$RENDER_DIR"
  mkdir -p "$BUNDLE_DIR"
  chmod 0700 "$BUNDLE_DIR"
  aws s3 cp "s3://${BUCKET}/${BUNDLE_PREFIX}/" "$BUNDLE_DIR/" --recursive >"$LOG_FILE" 2>&1 || die "bundle download failed"
  aws s3 cp "s3://${BUCKET}/${CONTRACT_KEY}" "$CONTRACT_FILE" >>"$LOG_FILE" 2>&1 || die "runtime contract download failed"
  if [[ -n "$EXPECTED_CONTRACT_SHA256" ]]; then
    [[ "$(sha256sum "$CONTRACT_FILE" | awk '{print $1}')" == "$EXPECTED_CONTRACT_SHA256" ]] || die "runtime contract checksum mismatch"
  fi
  if [[ -n "$VALUES_S3_KEY" ]]; then
    VALUES_FILE="$WORK_DIR/action-values.json"
    aws s3 cp "s3://${BUCKET}/${VALUES_S3_KEY}" "$VALUES_FILE" >>"$LOG_FILE" 2>&1 || die "action-time values download failed"
    if [[ -n "$EXPECTED_VALUES_SHA256" ]]; then
      [[ "$(sha256sum "$VALUES_FILE" | awk '{print $1}')" == "$EXPECTED_VALUES_SHA256" ]] || die "downloaded action-time values checksum mismatch"
    fi
  fi
  load_contract
  verify_bundle
}

normalize_legacy_load_balancer_controller_args() {
  # The S3 bundle root is the contents of k8s/ (base/, overlays/...), while
  # offline callers may hand this runner a full k8s/ tree.  Normalize the
  # downloaded bundle path first; otherwise the stale controller flag is
  # silently left in the rendered Deployment and the platform rollout
  # crash-loops before any ALB can be created.
  local deployment="$BUNDLE_DIR/base/platform-eks/aws-load-balancer-controller-deployment.yaml"
  if [[ ! -f "$deployment" ]]; then
    deployment="$BUNDLE_DIR/k8s/base/platform-eks/aws-load-balancer-controller-deployment.yaml"
  fi
  [[ -f "$deployment" ]] || return 0
  local changed
  changed="$(python3 - "$deployment" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
filtered = [line for line in lines if line.strip() != "- --enable-service-mutator-webhook=false"]
text = "".join(filtered)
changed = filtered != lines

# The canonical bundle predates the v3.3.0 webhook certificate requirement.
# Keep the compatibility repair isolated to the downloaded bundle: add the
# official Secret mount if it is absent, without changing the S3 revision.
mount_marker = "          volumeMounts:\n"
if "/tmp/k8s-webhook-server/serving-certs" not in text:
    resources_marker = "          resources:\n"
    if resources_marker not in text:
        raise SystemExit("controller deployment has no resources marker")
    mount = (
        "          volumeMounts:\n"
        "            - name: aws-load-balancer-webhook-tls\n"
        "              mountPath: /tmp/k8s-webhook-server/serving-certs\n"
        "              readOnly: true\n"
    )
    text = text.replace(resources_marker, mount + resources_marker, 1)
    changed = True

# v3.3.0 serves health probes on 61779; the historical bundle incorrectly
# points readiness/liveness at the metrics port (8080).
if "name: health\n              containerPort: 61779" not in text:
    metrics_ports = "          ports:\n            - name: metrics\n              containerPort: 8080\n"
    health_ports = metrics_ports + "            - name: health\n              containerPort: 61779\n"
    if metrics_ports not in text:
        raise SystemExit("controller deployment has no metrics port marker")
    text = text.replace(metrics_ports, health_ports, 1)
    changed = True
text = text.replace("path: /readyz\n              port: metrics", "path: /readyz\n              port: health")
text = text.replace("path: /healthz\n              port: metrics", "path: /healthz\n              port: health")

if "secretName: aws-load-balancer-webhook-tls" not in text:
    text = text.rstrip() + (
        "\n      volumes:\n"
        "        - name: aws-load-balancer-webhook-tls\n"
        "          secret:\n"
        "            secretName: aws-load-balancer-webhook-tls\n"
        "            defaultMode: 420\n"
    )
    changed = True

if changed:
    path.write_text(text, encoding="utf-8")
    print("true")
else:
    print("false")
PY
  )"
  if [[ "$changed" == true ]]; then
    printf 'stage=%s compatibility=removed-unsupported-aws-lbc-flag\n' "$STAGE" >&2
  fi
}

normalize_dev_eks_workload_compatibility() {
  # The EKS breakpoint node group is intentionally t3.medium 2/2/4. Normalize
  # only the downloaded compatibility copy; the canonical S3 bundle and its
  # revision stay immutable.  Measured requests/limits and the 0/1 rollout
  # are part of the comparison contract, while every affected container
  # remains explicitly non-root with a writable fsGroup.
  local workload_root="$BUNDLE_DIR/base"
  [[ -d "$workload_root" ]] || workload_root="$BUNDLE_DIR/k8s/base"
  [[ -d "$workload_root/backend/monolith" && -d "$workload_root/monitoring" ]] || return 0
  local changed cluster_name cluster_sg alb_sg
  cluster_name="$(jq -er '.cluster_name' "$CONTRACT_FILE")" || die "runtime contract cluster name is missing for compatibility normalization"
  alb_sg="$(jq -er '.alb_security_group_id' "$CONTRACT_FILE")" || die "runtime contract ALB security group is missing for compatibility normalization"
  [[ "$alb_sg" =~ ^sg-[0-9a-f]+$ ]] || die "runtime contract ALB security group is invalid"
  cluster_sg="$(aws eks describe-cluster --name "$cluster_name" --region "$EXPECTED_REGION" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>>"$LOG_FILE")" || die "EKS cluster security group lookup failed for compatibility normalization"
  [[ "$cluster_sg" =~ ^sg-[0-9a-f]+$ ]] || die "EKS cluster security group output is invalid"
  changed="$(python3 - "$workload_root" "$cluster_sg" "$alb_sg" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
cluster_sg = sys.argv[2]
alb_sg = sys.argv[3]

def patch_container(path: Path, name: str, old_memories: tuple[str, ...], new_memory: str, uid: int) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    marker = f"        - name: {name}"
    try:
        start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == marker)
    except StopIteration:
        return False
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("        - name: ") or lines[i].startswith("      volumes:")), len(lines))
    block = lines[start:end]
    changed = False
    in_requests = False
    for i, line in enumerate(block):
        if line.strip() == "requests:":
            in_requests = True
            continue
        if in_requests and line.strip() == "limits:":
            in_requests = False
        if in_requests and line.strip().startswith("memory:"):
            current = line.strip().split(":", 1)[1].strip()
            if current in old_memories and current != new_memory:
                block[i] = line.replace(current, new_memory, 1)
                changed = True
            break
    if not any(line.strip() == f"memory: {new_memory}" for line in block):
        raise SystemExit(f"{path}: {name} memory request marker is missing")
    if not any(line.strip().startswith("runAsUser:") for line in block):
        for i, line in enumerate(block):
            if line.strip() == "runAsNonRoot: true":
                indent = line[: len(line) - len(line.lstrip())]
                block[i + 1:i + 1] = [f"{indent}runAsUser: {uid}\n", f"{indent}runAsGroup: {uid}\n"]
                changed = True
                break
        else:
            raise SystemExit(f"{path}: {name} runAsNonRoot marker is missing")
    lines[start:end] = block
    if changed:
        path.write_text("".join(lines), encoding="utf-8")
    return changed

def ensure_backend_cpu_resources(path: Path) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    marker = "        - name: backend"
    try:
        start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == marker)
    except StopIteration:
        return False
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("        - name: ") or lines[i].startswith("      volumes:")), len(lines))
    block = lines[start:end]
    changed = False
    section = None
    for i, line in enumerate(block):
        stripped = line.strip()
        if stripped in {"requests:", "limits:"}:
            section = stripped[:-1]
            continue
        if stripped in {"requests:", "limits:"}:
            section = stripped[:-1]
        if section == "requests" and stripped.startswith("cpu:"):
            current = stripped.split(":", 1)[1].strip()
            if current in {"250m", "200m", "384m", "550m"} and current != "550m":
                block[i] = line.replace(current, "550m", 1)
                changed = True
        if section == "limits" and stripped.startswith("cpu:"):
            current = stripped.split(":", 1)[1].strip().strip('"')
            if current in {"1", "1000m", "400m", "1100m"} and current != "1100m":
                block[i] = line.replace(line.strip().split(":", 1)[1].strip(), "1100m", 1)
                changed = True
    if not any(line.strip() == "cpu: 550m" for line in block):
        raise SystemExit(f"{path}: backend CPU request marker is missing")
    if not any(line.strip() == "cpu: 1100m" for line in block):
        raise SystemExit(f"{path}: backend CPU limit marker is missing")
    lines[start:end] = block
    if changed:
        path.write_text("".join(lines), encoding="utf-8")
    return changed

def ensure_tmp_mount(path: Path, name: str, volume_name: str, size_limit: str) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    marker = f"        - name: {name}"
    try:
        start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == marker)
    except StopIteration:
        return False
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("        - name: ") or lines[i].startswith("      volumes:")), len(lines))
    block = lines[start:end]
    if any(line.strip() == "mountPath: /tmp" for line in block):
        return False
    volume_marker = "          volumeMounts:\n"
    try:
        mount_index = next(i for i, line in enumerate(block) if line == volume_marker)
    except StopIteration:
        raise SystemExit(f"{path}: {name} volumeMounts marker is missing")
    block[mount_index + 1:mount_index + 1] = [f"            - name: {volume_name}\n", "              mountPath: /tmp\n"]
    lines[start:end] = block
    volumes_index = next((i for i, line in enumerate(lines) if line == "      volumes:\n"), None)
    if volumes_index is None:
        raise SystemExit(f"{path}: volumes marker is missing")
    volume_end = len(lines)
    if any(line.strip() == f"- name: {volume_name}" for line in lines[volumes_index + 1:volume_end]):
        path.write_text("".join(lines), encoding="utf-8")
        return True
    lines[volume_end:volume_end] = [
        f"        - name: {volume_name}\n",
        "          emptyDir:\n",
        f"            sizeLimit: {size_limit}\n",
    ]
    path.write_text("".join(lines), encoding="utf-8")
    return True

def ensure_storage_parent_mount(path: Path, name: str) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    marker = f"        - name: {name}"
    try:
        start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == marker)
    except StopIteration:
        return False
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("        - name: ") or lines[i].startswith("      volumes:")), len(lines))
    block = lines[start:end]
    for i, line in enumerate(block):
        if line.strip() == "mountPath: /var/lib/alloy/data":
            block[i] = line.replace("/var/lib/alloy/data", "/var/lib/alloy", 1)
            lines[start:end] = block
            path.write_text("".join(lines), encoding="utf-8")
            return True
    return False

def ensure_fs_group_policy(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if "fsGroupChangePolicy: Always\n" in text:
        return False
    if "fsGroupChangePolicy: OnRootMismatch\n" in text:
        path.write_text(text.replace("fsGroupChangePolicy: OnRootMismatch\n", "fsGroupChangePolicy: Always\n", 1), encoding="utf-8")
        return True
    marker = "        fsGroup: 10001\n"
    if marker not in text:
        return False
    path.write_text(text.replace(marker, marker + "        fsGroupChangePolicy: Always\n", 1), encoding="utf-8")
    return True

def ensure_backend_rollout_strategy(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    # The EKS breakpoint campaign uses t3.medium 2/2/4 nodes. The prior
    # compatibility repair forced 1/0 and would make EKS's
    # availability envelope unfairly different from EC2's 100/150 rollout.
    # Normalize stale downloaded bundles back to the approved 0/1 contract.
    expected = "      maxUnavailable: 0\n      maxSurge: 1\n"
    legacy = "      maxUnavailable: 1\n      maxSurge: 0\n"
    if expected in text:
        return False
    if legacy not in text:
        return False
    path.write_text(text.replace(legacy, expected, 1), encoding="utf-8")
    return True

backend = root / "backend" / "monolith" / "deployment.yaml"
monitoring_alloy = root / "monitoring" / "alloy-daemonset.yaml"
ksm = root / "monitoring" / "kube-state-metrics-deployment.yaml"
changed = False
if backend.exists():
    changed |= ensure_backend_rollout_strategy(backend)
    changed |= ensure_fs_group_policy(backend)
    changed |= ensure_backend_cpu_resources(backend)
    changed |= patch_container(backend, "backend", ("640Mi", "512Mi", "448Mi", "384Mi"), "640Mi", 10001)
    changed |= patch_container(backend, "alloy-sidecar", ("256Mi", "128Mi", "64Mi"), "64Mi", 10001)
    changed |= ensure_storage_parent_mount(backend, "alloy-sidecar")
    changed |= ensure_tmp_mount(backend, "alloy-sidecar", "alloy-tmp", "128Mi")
if monitoring_alloy.exists():
    text = monitoring_alloy.read_text(encoding="utf-8")
    pod_marker = "      securityContext:\n        seccompProfile:\n"
    if "        fsGroup: 10001\n" not in text:
        if pod_marker not in text:
            raise SystemExit(f"{monitoring_alloy}: pod securityContext marker is missing")
        text = text.replace(pod_marker, "      securityContext:\n        fsGroup: 10001\n        seccompProfile:\n", 1)
        monitoring_alloy.write_text(text, encoding="utf-8")
        changed = True
    changed |= patch_container(monitoring_alloy, "alloy", ("256Mi", "128Mi", "64Mi"), "64Mi", 10001)
    changed |= ensure_storage_parent_mount(monitoring_alloy, "alloy")
    changed |= ensure_tmp_mount(monitoring_alloy, "alloy", "alloy-tmp", "128Mi")
    changed |= ensure_fs_group_policy(monitoring_alloy)
if ksm.exists():
    text = ksm.read_text(encoding="utf-8")
    pod_marker = "      securityContext:\n        seccompProfile:\n"
    if "        fsGroup: 10001\n" not in text:
        if pod_marker not in text:
            raise SystemExit(f"{ksm}: pod securityContext marker is missing")
        text = text.replace(pod_marker, "      securityContext:\n        fsGroup: 10001\n        seccompProfile:\n", 1)
        ksm.write_text(text, encoding="utf-8")
        changed = True
    changed |= patch_container(ksm, "kube-state-metrics", ("128Mi", "64Mi"), "64Mi", 10001)

platform = root / "platform"
platform_kustomization = platform / "kustomization.yaml"
delegated_binding = platform / "metrics-server-auth-delegator-clusterrolebinding.yaml"
if platform_kustomization.exists():
    if not delegated_binding.exists():
        delegated_binding.write_text(
            "apiVersion: rbac.authorization.k8s.io/v1\n"
            "kind: ClusterRoleBinding\n"
            "metadata:\n"
            "  name: metrics-server-auth-delegator\n"
            "  labels:\n"
            "    app.kubernetes.io/name: metrics-server\n"
            "    app.kubernetes.io/part-of: travel-planner-platform\n"
            "roleRef:\n"
            "  apiGroup: rbac.authorization.k8s.io\n"
            "  kind: ClusterRole\n"
            "  name: system:auth-delegator\n"
            "subjects:\n"
            "  - kind: ServiceAccount\n"
            "    name: metrics-server\n"
            "    namespace: kube-system\n",
            encoding="utf-8",
        )
        changed = True
    kustomization_text = platform_kustomization.read_text(encoding="utf-8")
    if "  - metrics-server-auth-delegator-clusterrolebinding.yaml\n" not in kustomization_text:
        marker = "  - metrics-server-auth-reader-rolebinding.yaml\n"
        if marker not in kustomization_text:
            raise SystemExit(f"{platform_kustomization}: metrics-server RBAC marker is missing")
        platform_kustomization.write_text(kustomization_text.replace(marker, marker + "  - metrics-server-auth-delegator-clusterrolebinding.yaml\n", 1), encoding="utf-8")
        changed = True

def ensure_ingress_security_group_strategy(path: Path, cluster_sg: str, alb_sg: str) -> bool:
    text = path.read_text(encoding="utf-8")
    marker = "  annotations:\n"
    if marker not in text:
        raise SystemExit(f"{path}: ingress annotations marker is missing")
    lines = text.splitlines(keepends=True)
    filtered = [
        line for line in lines
        if not line.lstrip().startswith("alb.ingress.kubernetes.io/manage-backend-security-group-rules:")
        and not line.lstrip().startswith("alb.ingress.kubernetes.io/security-groups:")
    ]
    annotations = (
        '    alb.ingress.kubernetes.io/manage-backend-security-group-rules: "false"\n'
        f'    alb.ingress.kubernetes.io/security-groups: {alb_sg},{cluster_sg}\n'
    )
    result = "".join(filtered).replace(marker, marker + annotations, 1)
    if result == text:
        return False
    path.write_text(result, encoding="utf-8")
    return True

ingress = root / "backend" / "monolith" / "ingress.yaml"
if ingress.exists():
    # Keep the EKS cluster SG private while attaching the disposable public
    # ALB SG. The cluster SG remains on the ALB as the source identity for
    # pod-target traffic; backend SG mutation stays disabled because the
    # cluster self-rule already covers the target path.
    changed |= ensure_ingress_security_group_strategy(ingress, cluster_sg, alb_sg)

print("true" if changed else "false")
PY
  )"
  if [[ -n "$REDIS_PRIMARY_ENDPOINT" ]]; then
    local redis_overlay="$BUNDLE_DIR/overlays/dev-eks-monolith/workload/backend-configmap.patch.yaml"
    [[ -f "$redis_overlay" ]] || die "dev-eks Redis overlay is missing from the bundle"
    local redis_changed
    redis_changed="$(python3 - "$redis_overlay" "$REDIS_PRIMARY_ENDPOINT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
endpoint = sys.argv[2]
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
host_matches = [index for index, line in enumerate(lines) if line.startswith("  SPRING_DATA_REDIS_HOST:")]
if len(host_matches) != 1:
    raise SystemExit(f"{path}: expected exactly one Redis host entry")
changed = False
host_index = host_matches[0]
host_replacement = f'  SPRING_DATA_REDIS_HOST: "{endpoint}"\n'
if lines[host_index] != host_replacement:
    lines[host_index] = host_replacement
    changed = True
username_matches = [index for index, line in enumerate(lines) if line.startswith("  SPRING_DATA_REDIS_USERNAME:")]
username_replacement = '  SPRING_DATA_REDIS_USERNAME: "default"\n'
if len(username_matches) > 1:
    raise SystemExit(f"{path}: expected at most one Redis username entry")
if not username_matches:
    lines.insert(host_index + 1, username_replacement)
    changed = True
elif lines[username_matches[0]] != username_replacement:
    lines[username_matches[0]] = username_replacement
    changed = True
if changed:
    path.write_text("".join(lines), encoding="utf-8")
print("true" if changed else "false")
PY
    )"
    if [[ "$redis_changed" == true ]]; then
      changed=true
      printf 'stage=%s compatibility=normalized-dev-eks-redis-primary-endpoint\n' "$STAGE" >&2
    fi
  fi
  if [[ "$changed" == true ]]; then
    printf 'stage=%s compatibility=normalized-dev-eks-workload-security-requests-and-alb-security-group-strategy\n' "$STAGE" >&2
  fi
}

ensure_controller_webhook_tls() {
  local secret_json tls_dir
  if secret_json="$(kubectl get secret aws-load-balancer-webhook-tls --namespace kube-system --output json 2>/dev/null)" \
    && jq -e '.type == "kubernetes.io/tls" and (.data."tls.crt" | type == "string" and length > 0) and (.data."tls.key" | type == "string" and length > 0)' <<<"$secret_json" >/dev/null; then
    return 0
  fi
  command -v openssl >/dev/null 2>&1 || die "openssl is required to bootstrap the controller webhook certificate"
  tls_dir="$WORK_DIR/controller-webhook-tls"
  rm -rf -- "$tls_dir"
  mkdir -p "$tls_dir"
  chmod 0700 "$tls_dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -subj "/CN=aws-load-balancer-webhook-service.kube-system.svc" \
    -addext "subjectAltName=DNS:aws-load-balancer-webhook-service.kube-system.svc,DNS:aws-load-balancer-webhook-service" \
    -keyout "$tls_dir/tls.key" -out "$tls_dir/tls.crt" >>"$LOG_FILE" 2>&1 || die "controller webhook certificate generation failed"
  kubectl create secret tls aws-load-balancer-webhook-tls \
    --namespace kube-system --cert "$tls_dir/tls.crt" --key "$tls_dir/tls.key" \
    --dry-run=client --output yaml \
    | kubectl apply --filename - >>"$LOG_FILE" 2>&1 || die "controller webhook Secret bootstrap failed"
  rm -rf -- "$tls_dir"
}

write_state() {
  local status="$1"
  local render_sha="${2:-}"
  local values_sha="${3:-}"
  local completed_stages='[]'
  if [[ -s "$STATE_FILE" ]]; then
    completed_stages="$(jq -c '.completed_stages // []' "$STATE_FILE" 2>/dev/null || printf '[]')"
    if [[ -z "$values_sha" ]]; then
      values_sha="$(jq -r '.values_sha256 // empty' "$STATE_FILE" 2>/dev/null || true)"
    fi
  fi
  jq -n \
    --arg schema "dev-eks-runner-state/v1" \
    --arg stage "$STAGE" \
    --arg status "$status" \
    --arg cluster "$(jq -r '.cluster_name' "$CONTRACT_FILE")" \
    --arg revision "$EXPECTED_BUNDLE_REVISION" \
    --arg render "$render_sha" \
    --arg values "$values_sha" \
    --argjson completed "$completed_stages" \
    '{schema_version:$schema, stage:$stage, status:$status, cluster_name:$cluster, bundle_revision_sha256:$revision, render_sha256:$render, values_sha256:$values, completed_stages:(($completed + [$stage]) | unique)}' \
    >"$STATE_FILE"
}

require_prepared() {
  [[ -s "$STATE_FILE" ]] || die "prepare stage has not completed"
  jq -e --arg revision "$EXPECTED_BUNDLE_REVISION" '.schema_version == "dev-eks-runner-state/v1" and .status == "success" and .bundle_revision_sha256 == $revision and (.render_sha256 | test("^[0-9a-f]{64}$"))' "$STATE_FILE" >/dev/null || die "prepared state is stale or incomplete"
  if [[ -n "$EXPECTED_VALUES_SHA256" ]]; then
    jq -e --arg values "$EXPECTED_VALUES_SHA256" '.values_sha256 == $values' "$STATE_FILE" >/dev/null || die "action-time values do not match the prepared state"
  fi
  if [[ -n "$EXPECTED_RENDER_SHA256" ]]; then
    [[ "$(jq -r '.render_sha256' "$STATE_FILE")" == "$EXPECTED_RENDER_SHA256" ]] || die "render sha256 does not match the approved value"
  fi
  if [[ -n "$VALUES_S3_KEY" && "$STAGE" != "prepare" ]]; then
    download_bundle_and_contract
    # Every resumed stage re-downloads the canonical bundle before rendering.
    # Repeat the same isolated compatibility normalization here so the
    # prepared render hash remains stable across stage boundaries.
    normalize_legacy_load_balancer_controller_args
    normalize_dev_eks_workload_compatibility
    python3 "$BUNDLE_DIR/scripts/eks/render-monolith-action-time.py" \
      --source-root "$BUNDLE_DIR" \
      --output-root "$RENDER_DIR" \
      --inputs "$VALUES_FILE" \
      --contract "$CONTRACT_FILE" \
      --summary "$WORK_DIR/revalidated-render-summary.json" \
      >"$WORK_DIR/revalidated-render-result.json" 2>>"$LOG_FILE" || die "resume action-time render failed"
    [[ "$(jq -r '.render_sha256' "$WORK_DIR/revalidated-render-summary.json")" == "$(jq -r '.render_sha256' "$STATE_FILE")" ]] || die "resume render hash does not match the prepared state"
  else
    [[ -d "$RENDER_DIR/overlays/dev-eks-monolith" ]] || die "rendered source is missing"
    load_contract
    verify_bundle
  fi
}

require_completed_stage() {
  local required_stage="$1"
  jq -e --arg required "$required_stage" '.completed_stages | index($required) != null' "$STATE_FILE" >/dev/null || die "required prior stage is not complete: $required_stage"
  case "$required_stage" in
    namespace-secret) verify_secret_postcondition ;;
    platform) verify_platform_postcondition ;;
    workload) verify_workload_postcondition ;;
  esac
}

prepare() {
  download_bundle_and_contract
  normalize_legacy_load_balancer_controller_args
  normalize_dev_eks_workload_compatibility
  rm -f -- "$STATE_FILE" "$SUMMARY_FILE"
  local cluster region
  cluster="$(jq -r '.cluster_name' "$CONTRACT_FILE")"
  region="$(jq -r '.aws_region' "$CONTRACT_FILE")"
  aws eks update-kubeconfig --name "$cluster" --region "$region" --kubeconfig "$KUBECONFIG_PATH" >"$LOG_FILE" 2>&1 || die "kubeconfig update failed"
  kubectl get --raw=/version >"$WORK_DIR/cluster-version.json" 2>>"$LOG_FILE" || die "cluster identity check failed"
  kubectl get nodes --no-headers >"$WORK_DIR/nodes.txt" 2>>"$LOG_FILE" || die "read-only node check failed"
  python3 "$BUNDLE_DIR/scripts/eks/render-monolith-action-time.py" \
    --source-root "$BUNDLE_DIR" \
    --output-root "$RENDER_DIR" \
    --inputs "$VALUES_FILE" \
    --contract "$CONTRACT_FILE" \
    --summary "$WORK_DIR/render-summary.json" \
    >"$WORK_DIR/render-result.json" 2>>"$LOG_FILE" || die "action-time render failed"
  local render_sha
  render_sha="$(jq -r '.render_sha256' "$WORK_DIR/render-summary.json")"
  [[ "$render_sha" =~ ^[0-9a-f]{64}$ ]] || die "renderer returned an invalid aggregate hash"
  local values_sha
  values_sha="$(sha256sum "$VALUES_FILE" | awk '{print $1}')"
  if [[ -n "$EXPECTED_VALUES_SHA256" && "$values_sha" != "$EXPECTED_VALUES_SHA256" ]]; then
    die "downloaded action-time values do not match the explicit input hash"
  fi
  write_state success "$render_sha" "$values_sha"
  jq -n --arg stage prepare --arg status success --arg cluster "$cluster" --arg revision "$EXPECTED_BUNDLE_REVISION" --arg render "$render_sha" '{schema_version:"dev-eks-deployment-summary/v1",stage:$stage,status:$status,cluster_name:$cluster,bundle_revision_sha256:$revision,render_sha256:$render}' >"$SUMMARY_FILE"
  printf 'stage=prepare status=success render_sha256=%s\n' "$render_sha" >&2
}

verify_secret_postcondition() {
  kubectl get secret backend-secret --namespace travel-planner --output json 2>>"$LOG_FILE" \
    | jq '{metadata:{name:.metadata.name,namespace:.metadata.namespace},data:(.data | keys | map({(.): null}) | add)}' \
    >"$WORK_DIR/secret-metadata.json" || die "backend Secret verification failed"
  jq -e '
    .metadata.name == "backend-secret" and
    .metadata.namespace == "travel-planner" and
    ((.data | keys | sort) == [
      "GOOGLE_MAPS_API_KEY", "GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET",
      "JWT_SECRET", "NAVER_OAUTH_CLIENT_ID", "NAVER_OAUTH_CLIENT_SECRET",
      "SPRING_DATASOURCE_PASSWORD", "SPRING_DATASOURCE_USERNAME", "SPRING_DATA_REDIS_PASSWORD"
    ])
  ' "$WORK_DIR/secret-metadata.json" >/dev/null || die "backend Secret name/key-set verification failed"
}

verify_platform_postcondition() {
  verify_platform_resource() {
    local namespace="$1" deployment="$2" serviceaccount="$3"
    local deployment_json="$WORK_DIR/platform-${deployment}.json"
    kubectl get serviceaccount "$serviceaccount" --namespace "$namespace" --output name >>"$LOG_FILE" 2>&1 || die "platform ServiceAccount is missing: $namespace/$serviceaccount"
    kubectl get deployment "$deployment" --namespace "$namespace" --output json >"$deployment_json" 2>>"$LOG_FILE" || die "platform Deployment is missing: $namespace/$deployment"
    jq -e '([.status.conditions[]? | select(.type == "Available" and .status == "True")] | length >= 1)' "$deployment_json" >/dev/null || die "platform Deployment is not Available: $namespace/$deployment"
  }
  wait_rollout kube-system deployment/aws-load-balancer-controller
  wait_rollout kube-system deployment/metrics-server
  wait_rollout kube-system deployment/cluster-autoscaler
  verify_platform_resource kube-system aws-load-balancer-controller aws-load-balancer-controller
  verify_platform_resource kube-system metrics-server metrics-server
  verify_platform_resource kube-system cluster-autoscaler cluster-autoscaler
}

verify_workload_postcondition() {
  wait_rollout travel-planner deployment/backend
  wait_rollout travel-planner-monitoring deployment/kube-state-metrics
  wait_rollout travel-planner-monitoring daemonset/alloy
  kubectl get deployment backend --namespace travel-planner --output json >"$WORK_DIR/backend-deployment.json" 2>>"$LOG_FILE" || die "backend readiness check failed"
  jq -e '(.status.readyReplicas // 0) >= 2' "$WORK_DIR/backend-deployment.json" >/dev/null || die "backend has fewer than two Ready replicas"
  kubectl get hpa backend --namespace travel-planner --output json >"$WORK_DIR/backend-hpa.json" 2>>"$LOG_FILE" || die "backend HPA check failed"
  jq -e '.spec.minReplicas == 2 and .spec.maxReplicas == 4' "$WORK_DIR/backend-hpa.json" >/dev/null || die "backend HPA bounds are not 2/4"
}

apply_namespace_and_secret() {
  require_prepared
  # The workload overlay contains both the backend and monitoring trees.  The
  # API server validates object namespaces during `kubectl diff`, so bootstrap
  # both namespaces before the first workload diff rather than relying on
  # Kustomize's resource ordering.
  kubectl apply \
    --filename "$RENDER_DIR/base/backend/monolith/namespace.yaml" \
    --filename "$RENDER_DIR/base/monitoring/namespace.yaml" \
    >"$LOG_FILE" 2>&1 || die "namespace apply failed"
  local application_secret database_secret redis_secret
  application_secret="$(jq -r '.backend_application_secret_arn' "$CONTRACT_FILE")"
  database_secret="$(jq -r '.database_master_secret_arn' "$CONTRACT_FILE")"
  redis_secret="$(jq -r '.redis_auth_secret_arn' "$CONTRACT_FILE")"
  bash "$BUNDLE_DIR/scripts/eks/bootstrap-backend-secret.sh" "$application_secret" "$database_secret" "$redis_secret" >>"$LOG_FILE" 2>&1 || die "backend Secret bootstrap failed"
  verify_secret_postcondition
  write_state success "$(jq -r '.render_sha256' "$STATE_FILE")"
  jq -n '{schema_version:"dev-eks-deployment-summary/v1",stage:"namespace-secret",status:"success",secret_name:"backend-secret",secret_key_count:9}' >"$SUMMARY_FILE"
  printf 'stage=namespace-secret status=success\n' >&2
}

kubectl_diff_and_apply() {
  local root="$1"
  set +e
  kubectl diff --kustomize "$root" >"$LOG_FILE" 2>&1
  local diff_status=$?
  set -e
  ((diff_status <= 1)) || die "kubernetes diff failed"
  kubectl apply --kustomize "$root" >>"$LOG_FILE" 2>&1 || die "kubernetes apply failed"
}

wait_rollout() {
  local namespace="$1" resource="$2"
  kubectl rollout status "$resource" --namespace "$namespace" --timeout "$ROLLOUT_TIMEOUT" >>"$LOG_FILE" 2>&1 || die "rollout failed"
}

apply_platform() {
  require_prepared
  require_completed_stage namespace-secret
  ensure_controller_webhook_tls
  kubectl_diff_and_apply "$RENDER_DIR/overlays/dev-eks-monolith/platform"
  verify_platform_postcondition
  write_state success "$(jq -r '.render_sha256' "$STATE_FILE")"
  jq -n '{schema_version:"dev-eks-deployment-summary/v1",stage:"platform",status:"success",rollouts:["deployment/aws-load-balancer-controller","deployment/metrics-server","deployment/cluster-autoscaler"]}' >"$SUMMARY_FILE"
  printf 'stage=platform status=success\n' >&2
}

apply_workload() {
  require_prepared
  require_completed_stage platform
  kubectl_diff_and_apply "$RENDER_DIR/overlays/dev-eks-monolith/workload"
  verify_workload_postcondition
  write_state success "$(jq -r '.render_sha256' "$STATE_FILE")"
  jq -n '{schema_version:"dev-eks-deployment-summary/v1",stage:"workload",status:"success",backend_ready_replicas:2,hpa_min_replicas:2,hpa_max_replicas:4}' >"$SUMMARY_FILE"
  printf 'stage=workload status=success\n' >&2
}

wait_for_ingress() {
  require_prepared
  require_completed_stage workload
  local deadline=$((SECONDS + INGRESS_TIMEOUT_SECONDS))
  local hostname=""
  while ((SECONDS < deadline)); do
    hostname="$(kubectl get ingress backend --namespace travel-planner --output json 2>>"$LOG_FILE" | jq -r '[.status.loadBalancer.ingress[]?.hostname // empty] | if length == 1 then .[0] else empty end' || true)"
    if [[ "$hostname" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+elb\.amazonaws\.com$ && ${#hostname} -le 253 ]]; then
      write_state success "$(jq -r '.render_sha256' "$STATE_FILE")"
      jq -n --arg hostname "$hostname" '{schema_version:"dev-eks-deployment-summary/v1",stage:"ingress-wait",status:"success",cloudflare_cname_target:$hostname}' >"$SUMMARY_FILE"
      printf 'CLOUDFLARE_CNAME_TARGET=%s\n' "$hostname"
      return 0
    fi
    sleep 10
  done
  die "Ingress ALB hostname did not become ready before timeout"
}

case "$STAGE" in
  prepare) prepare ;;
  namespace-secret) apply_namespace_and_secret ;;
  platform) apply_platform ;;
  workload) apply_workload ;;
  ingress-wait) wait_for_ingress ;;
esac
