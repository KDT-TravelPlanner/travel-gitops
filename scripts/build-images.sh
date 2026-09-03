#!/usr/bin/env bash
# 4개 서비스 컨테이너 이미지를 <svc>-service:local 태그로 빌드한다.
# 각 서비스 레포는 사전 빌드된 JAR(build/libs/app.jar)만 이미지에 넣으므로,
# 여기서 gradlew bootJar 를 먼저 돌린 뒤 docker build 한다.
#
# 환경변수:
#   SERVICE_REPOS_DIR  서비스 레포들이 있는 상위 디렉터리 (기본: $HOME/github)
#   JAVA_HOME          미설정 시 Homebrew openjdk@21 경로를 시도한다
set -euo pipefail

REPOS_DIR="${SERVICE_REPOS_DIR:-$HOME/github}"
SERVICES=(identity community travel maps)

if [[ -z "${JAVA_HOME:-}" ]]; then
  CANDIDATE="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
  [[ -x "$CANDIDATE/bin/java" ]] && export JAVA_HOME="$CANDIDATE"
fi
echo "JAVA_HOME=${JAVA_HOME:-<unset>}"

for svc in "${SERVICES[@]}"; do
  repo="$REPOS_DIR/${svc}-service"
  [[ -d "$repo" ]] || { echo "error: $repo 없음 (SERVICE_REPOS_DIR 확인)" >&2; exit 1; }
  echo "==> $svc: bootJar"
  ( cd "$repo" && ./gradlew bootJar --offline -q --console=plain )
  echo "==> $svc: docker build -> ${svc}-service:local"
  docker build -q -t "${svc}-service:local" "$repo" >/dev/null
done

echo "완료:"
docker images | grep -E '^(identity|community|travel|maps)-service +local' || true
