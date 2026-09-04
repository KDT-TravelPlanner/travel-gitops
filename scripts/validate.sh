#!/usr/bin/env bash
# 모든 kustomization 을 build 하고, 결과 매니페스트를 kubeconform 으로 스키마 검증한다.
# 로컬에서도 그대로 실행: ./scripts/validate.sh
#
# 필요 도구: kustomize, kubeconform (없으면 설치 안내)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

KUSTOMIZE="${KUSTOMIZE:-kustomize}"
KUBECONFORM="${KUBECONFORM:-kubeconform}"
K8S_VERSION="${K8S_VERSION:-1.30.0}"

for bin in "$KUSTOMIZE" "$KUBECONFORM"; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "error: '$bin' 없음." >&2
    echo "  kustomize:   https://kubectl.docs.kubernetes.io/installation/kustomize/" >&2
    echo "  kubeconform: https://github.com/yannh/kubeconform#installation" >&2
    exit 2; }
done

# kustomization.yaml 이 있는 모든 디렉터리 (bootstrap/install, clusters/kind-dev/ingress-nginx 등
# 원격 base 도 포함). 하위 디렉터리를 자동 발견하므로 새 오버레이가 생겨도 수정 불필요.
DIRS=()
while IFS= read -r f; do
  DIRS+=("$(dirname "$f")")
done < <(find . -name kustomization.yaml -not -path './.git/*' | sort)

[ "${#DIRS[@]}" -gt 0 ] || { echo "error: kustomization.yaml 을 못 찾음" >&2; exit 2; }

fail=0
for d in "${DIRS[@]}"; do
  echo "── kustomize build ${d#./}"
  if ! out="$("$KUSTOMIZE" build "$d" 2>&1)"; then
    echo "$out"
    echo "❌ kustomize build 실패: ${d#./}"
    fail=1
    continue
  fi
  # Application/AppProject 등 CRD 는 스키마가 없으므로 무시. 나머지는 strict 검증.
  if ! echo "$out" | "$KUBECONFORM" \
        -strict -ignore-missing-schemas \
        -kubernetes-version "$K8S_VERSION" \
        -summary 2>&1; then
    echo "❌ kubeconform 검증 실패: ${d#./}"
    fail=1
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "✅ 전체 통과 (${#DIRS[@]}개 kustomization)"
else
  echo "❌ 실패 항목 있음"
fi
exit "$fail"
