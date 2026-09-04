#!/usr/bin/env bash
# Kind 클러스터에 Argo CD 를 설치하고 travel-planner 스택을 GitOps 로 동기화한다.
#   1. (사전) kind 클러스터 + <svc>-service:local 이미지 로드  ← setup.sh 또는 아래 안내
#   2. Secret 5개 생성 (Argo CD 밖 — 레포에 실값 없음)
#   3. Argo CD 설치 (bootstrap/install)
#   4. AppProject + root-app apply  → Argo 가 platform + 4개 서비스를 sync
#
# 이미지는 아직 레지스트리에 push 하지 않으므로 kind load 는 여전히 수동이다.
# (레지스트리 확정 후 CI push 로 대체 예정)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="travel-planner-local"
NAMESPACE="travel-planner"
SERVICES=(identity community travel maps)

for bin in kind kubectl docker; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' 없음" >&2; exit 1; }
done

kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" || {
  echo "error: kind cluster '$CLUSTER_NAME' 없음. 먼저:" >&2
  echo "  kind create cluster --config clusters/kind-dev/kind-config.yaml" >&2
  exit 1
}

echo "-> 이미지 로드 (kind load)"
for svc in "${SERVICES[@]}"; do
  img="${svc}-service:local"
  docker image inspect "$img" >/dev/null 2>&1 || {
    echo "error: 이미지 '$img' 없음. scripts/build-images.sh 먼저." >&2; exit 1; }
  kind load docker-image "$img" --name "$CLUSTER_NAME"
done

echo "-> Secret 5개"
"$SCRIPT_DIR/create-secrets.sh" "$NAMESPACE"

echo "-> Argo CD 설치"
kubectl apply -k "$REPO_ROOT/bootstrap/install"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s 2>/dev/null || \
  kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=180s

echo "-> AppProject + root-app"
kubectl apply -f "$REPO_ROOT/bootstrap/project.yaml"
kubectl apply -f "$REPO_ROOT/bootstrap/root-app.yaml"

echo
echo "완료. Argo CD sync 확인:"
echo "  kubectl -n argocd get applications"
echo "  kubectl -n travel-planner get pods"
echo
echo "Argo CD UI:"
echo "  kubectl -n argocd port-forward svc/argocd-server 8081:80 &"
echo "  open http://localhost:8081   (user: admin)"
echo "  초기 비밀번호: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo
echo "주의: travel-gitops 가 private 레포면 Argo CD 에 repo 자격증명을 등록해야 한다."
echo "  argocd repo add https://github.com/protove/travel-gitops.git --username <user> --password <PAT>"
echo "  (또는 argocd-repo-creds Secret 을 직접 apply)"
