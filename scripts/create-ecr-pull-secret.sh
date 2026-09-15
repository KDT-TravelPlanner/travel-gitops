#!/usr/bin/env bash
set -euo pipefail

# Kind 노드는 AWS IAM Role이 없으므로 private ECR pull용 Docker registry Secret이 필요하다.
# ECR 인증 토큰은 12시간 뒤 만료한다. 이 스크립트는 값이 아닌 갱신 방법만 Git에 보관한다.

NAMESPACE="${1:-travel-planner}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
ECR_REGISTRY="${ECR_REGISTRY:-419496180357.dkr.ecr.ap-northeast-2.amazonaws.com}"
SECRET_NAME="${ECR_PULL_SECRET_NAME:-ecr-registry}"

command -v aws >/dev/null || { echo "aws CLI가 필요합니다." >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl이 필요합니다." >&2; exit 1; }

token="$(aws ecr get-login-password --region "${AWS_REGION}")"

kubectl -n "${NAMESPACE}" create secret docker-registry "${SECRET_NAME}" \
  --docker-server="${ECR_REGISTRY}" \
  --docker-username=AWS \
  --docker-password="${token}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

echo "${SECRET_NAME} 갱신 완료 (${NAMESPACE}). ECR 인증 토큰은 약 12시간 뒤 갱신해야 합니다."
