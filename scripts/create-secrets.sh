#!/usr/bin/env bash
# travel-planner-secret 계열 5개를 secrets/*.dev.env 로부터 생성/갱신한다.
# setup.sh(수동 배포)와 argocd-bootstrap.sh(GitOps) 양쪽에서 쓴다.
# 매니페스트에 실값을 커밋하지 않으므로 이 단계는 Argo CD 밖에서 처리한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${1:-travel-planner}"

SECRETS=(
  "postgres-secret:postgres"
  "redis-secret:redis"
  "jwt-secret:jwt"
  "identity-oauth-secret:identity-oauth"
  "maps-secret:maps"
)

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

for pair in "${SECRETS[@]}"; do
  name="${pair%%:*}"
  file="$REPO_ROOT/secrets/${pair#*:}.dev.env"
  [[ -f "$file" ]] || {
    echo "error: $file 없음. cp ${file}.example $file 후 값을 채워라." >&2; exit 1; }
  kubectl create secret generic "$name" \
    -n "$NAMESPACE" \
    --from-env-file="$file" \
    --dry-run=client -o yaml | kubectl apply -f -
done
