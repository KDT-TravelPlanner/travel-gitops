#!/usr/bin/env bash
# SCRUM-128 1회성 전환 도구.
# 기존 root Application은 clusters/kind-dev/applications 경로를 기억한다.
# 이 레이아웃 PR이 develop에 반영된 뒤 새 Argo CD 경로로 갱신한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v kubectl >/dev/null 2>&1 || {
  echo "error: 'kubectl' 명령을 찾을 수 없다." >&2
  exit 1
}

kubectl -n argocd get application travel-planner >/dev/null 2>&1 || {
  echo "error: argocd namespace에 travel-planner root Application이 없다." >&2
  echo "새 Kind 클러스터라면 ./scripts/argocd-bootstrap.sh 를 실행해라." >&2
  exit 1
}

echo "-> AppProject 경로 적용"
kubectl apply -f "$REPO_ROOT/argocd/project.yaml"

echo "-> root Application을 argocd/applications/kind-dev 경로로 전환"
kubectl apply -f "$REPO_ROOT/argocd/root-app-kind-dev.yaml"

echo
echo "완료. 다음으로 동기화 상태를 확인:"
echo "  kubectl -n argocd get applications"
