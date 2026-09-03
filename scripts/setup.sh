#!/usr/bin/env bash
# Kind 개발 클러스터를 만들고 travel-planner 스택 전체를 올린다.
#   1. kind 클러스터 생성 (없으면)
#   2. <svc>-service:local 이미지 4개를 kind 노드로 로드
#   3. namespace + travel-planner-secret(로컬 env 파일 기준) 적용
#   4. kubectl apply -k clusters/kind-dev  (platform + 4개 서비스)
#   5. rollout 대기
#
# 사전: scripts/build-images.sh 로 이미지 4개를 먼저 빌드해둔다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER_NAME="travel-planner-local"
NAMESPACE="travel-planner"
ENV_FILE="$REPO_ROOT/secrets/.env.kind-dev"
SERVICES=(identity community travel maps)

for bin in kind kubectl docker; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' 명령을 찾을 수 없다." >&2; exit 1; }
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE 없음. cp secrets/.env.kind-dev.example secrets/.env.kind-dev 후 값을 채워라." >&2
  exit 1
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "-> kind cluster '$CLUSTER_NAME' 이미 있음, 생성 생략"
else
  echo "-> kind cluster 생성"
  kind create cluster --config "$REPO_ROOT/clusters/kind-dev/kind-config.yaml"
fi

echo "-> 이미지 로드"
for svc in "${SERVICES[@]}"; do
  img="${svc}-service:local"
  docker image inspect "$img" >/dev/null 2>&1 || {
    echo "error: 이미지 '$img' 없음. 먼저 scripts/build-images.sh 를 실행해라." >&2; exit 1; }
  kind load docker-image "$img" --name "$CLUSTER_NAME"
done

echo "-> namespace"
kubectl apply -f "$REPO_ROOT/clusters/kind-dev/platform/namespace.yaml"

echo "-> travel-planner-secret (재실행 시 갱신)"
kubectl create secret generic travel-planner-secret \
  -n "$NAMESPACE" \
  --from-env-file="$ENV_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "-> kubectl apply -k clusters/kind-dev"
kubectl apply -k "$REPO_ROOT/clusters/kind-dev"

echo "-> postgres/redis Ready 대기"
kubectl -n "$NAMESPACE" rollout status deploy/postgres --timeout=180s
kubectl -n "$NAMESPACE" rollout status deploy/redis --timeout=120s

echo "-> 서비스 Ready 대기 (Flyway 마이그레이션 포함)"
for svc in "${SERVICES[@]}"; do
  kubectl -n "$NAMESPACE" rollout status "deploy/$svc" --timeout=300s
done

echo
echo "완료. 확인:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl port-forward -n $NAMESPACE svc/identity 9091:9091 &"
echo "  curl localhost:9091/actuator/health/readiness"
