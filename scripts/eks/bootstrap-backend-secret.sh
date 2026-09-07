#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s APPLICATION_SECRET_ARN DATABASE_SECRET_ARN REDIS_SECRET_ARN [NAMESPACE] [SECRET_NAME]\n' "$0" >&2
}

if [[ $# -lt 3 || $# -gt 5 ]]; then
  usage
  exit 64
fi

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
NAMESPACE="${4:-travel-planner}"
SECRET_NAME="${5:-backend-secret}"
APPLICATION_SECRET_ARN="$1"
DATABASE_SECRET_ARN="$2"
REDIS_SECRET_ARN="$3"

for command_name in aws jq kubectl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'Required command is unavailable: %s\n' "$command_name" >&2
    exit 127
  }
done

for value_name in APPLICATION_SECRET_ARN DATABASE_SECRET_ARN REDIS_SECRET_ARN NAMESPACE SECRET_NAME; do
  [[ -n "${!value_name}" ]] || {
    printf 'Required value is empty: %s\n' "$value_name" >&2
    exit 64
  }
done

umask 077
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/travel-planner-secret.XXXXXX")"
chmod 0700 "$tmp_dir"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$APPLICATION_SECRET_ARN" \
  --query SecretString \
  --output text >"$tmp_dir/application.json"
aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$DATABASE_SECRET_ARN" \
  --query SecretString \
  --output text >"$tmp_dir/database.json"
aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$REDIS_SECRET_ARN" \
  --query SecretString \
  --output text >"$tmp_dir/redis.json"

jq -e '
  type == "object" and
  (.JWT_SECRET | type == "string" and length > 0) and
  (.GOOGLE_OAUTH_CLIENT_ID | type == "string" and length > 0) and
  (.GOOGLE_OAUTH_CLIENT_SECRET | type == "string" and length > 0) and
  (.NAVER_OAUTH_CLIENT_ID | type == "string" and length > 0) and
  (.NAVER_OAUTH_CLIENT_SECRET | type == "string" and length > 0) and
  (.GOOGLE_MAPS_API_KEY | type == "string" and length > 0)
' "$tmp_dir/application.json" >/dev/null
jq -e 'type == "object" and (.username | type == "string" and length > 0) and (.password | type == "string" and length > 0)' \
  "$tmp_dir/database.json" >/dev/null
jq -e 'type == "object" and (.password | type == "string" and length > 0)' \
  "$tmp_dir/redis.json" >/dev/null

jq -s '
  .[0] as $application |
  .[1] as $database |
  .[2] as $redis |
  {
    SPRING_DATASOURCE_USERNAME: $database.username,
    SPRING_DATASOURCE_PASSWORD: $database.password,
    SPRING_DATA_REDIS_PASSWORD: $redis.password,
    JWT_SECRET: $application.JWT_SECRET,
    GOOGLE_OAUTH_CLIENT_ID: $application.GOOGLE_OAUTH_CLIENT_ID,
    GOOGLE_OAUTH_CLIENT_SECRET: $application.GOOGLE_OAUTH_CLIENT_SECRET,
    NAVER_OAUTH_CLIENT_ID: $application.NAVER_OAUTH_CLIENT_ID,
    NAVER_OAUTH_CLIENT_SECRET: $application.NAVER_OAUTH_CLIENT_SECRET,
    GOOGLE_MAPS_API_KEY: $application.GOOGLE_MAPS_API_KEY
  }
' "$tmp_dir/application.json" "$tmp_dir/database.json" "$tmp_dir/redis.json" >"$tmp_dir/backend.json"

secret_keys=(
  SPRING_DATASOURCE_USERNAME
  SPRING_DATASOURCE_PASSWORD
  SPRING_DATA_REDIS_PASSWORD
  JWT_SECRET
  GOOGLE_OAUTH_CLIENT_ID
  GOOGLE_OAUTH_CLIENT_SECRET
  NAVER_OAUTH_CLIENT_ID
  NAVER_OAUTH_CLIENT_SECRET
  GOOGLE_MAPS_API_KEY
)
from_files=()
for secret_key in "${secret_keys[@]}"; do
  jq -e -j --arg key "$secret_key" '.[$key] | strings | select(length > 0)' \
    "$tmp_dir/backend.json" >"$tmp_dir/$secret_key"
  chmod 0600 "$tmp_dir/$secret_key"
  from_files+=("--from-file=${secret_key}=${tmp_dir}/${secret_key}")
done

kubectl_exec() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    command kubectl --context "$KUBE_CONTEXT" "$@"
  else
    command kubectl "$@"
  fi
}

kubectl_exec --namespace "$NAMESPACE" create secret generic "$SECRET_NAME" \
  "${from_files[@]}" \
  --dry-run=client \
  --output yaml |
  kubectl_exec apply --filename -

printf 'Backend Secret applied: namespace=%s name=%s keys=%s\n' \
  "$NAMESPACE" "$SECRET_NAME" "${#secret_keys[@]}"
