#!/usr/bin/env bash
# Kind 개발 클러스터를 통째로 삭제한다 (PVC 데이터도 함께 사라진다 — 의도된 휘발성).
set -euo pipefail

CLUSTER_NAME="travel-planner-local"

command -v kind >/dev/null 2>&1 || { echo "error: 'kind' 명령을 찾을 수 없다." >&2; exit 1; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "kind cluster '$CLUSTER_NAME' 없음, 삭제할 게 없음"
fi
