#!/usr/bin/env python3
"""Kind(travel-planner) 부하/기능 테스트용 합성 데이터 시드.

모놀리스 scripts/loadtest/seed-compose-load-data.py 의 MSA/Kind 이식본.
테스트 전용 백엔드 엔드포인트를 추가하지 않고 **실제 런타임 계약**을 그대로 쓴다:

  1. identity.user_table 에 합성 사용자 INSERT
  2. Redis 에 refresh-token family 를 직접 심는다
     (auth:refresh:token:<sha256hex>, auth:refresh:family:<familyId>, auth:refresh:user:<userId>)
  3. 실제 POST /api/v1/auth/token/refresh 를 한 번 호출해 회전 쿠키·access token 을 검증
  4. 사용자별 Travel 1개 + visitOrder 1~3 Timeline 3개 생성
  5. loadtest/data/data.json 에 최소 credential 만 0600 으로 기록

접근은 docker compose 가 아니라 kubectl exec (Kind 클러스터). DB/Redis 자격증명은
클러스터의 Secret 에서 읽는다. base-url 은 ingress(http://localhost) 기본.

usage:
  ./loadtest/seed-kind-load-data.py --users 20
  ./loadtest/seed-kind-load-data.py --tokens-only        # data.json 의 유저로 refresh 토큰만 재발급
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA_FILE = REPO_ROOT / "loadtest/data/data.json"
DEFAULT_NAMESPACE = "travel-planner"
DEFAULT_BASE_URL = "http://localhost"
DEFAULT_REFRESH_TTL_MS = 30 * 24 * 60 * 60 * 1000  # 30d (identity ${REFRESH_TOKEN_TTL:30d})
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{43}$")


class SeedError(RuntimeError):
    """정제된 시드/계약 검증 실패."""


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def new_opaque_token() -> str:
    token = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode("ascii").rstrip("=")
    if not TOKEN_PATTERN.fullmatch(token):
        raise SeedError("generated opaque token has an invalid format")
    return token


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--users", type=int, default=20, help="합성 사용자 수 (1~200)")
    parser.add_argument("--tokens-only", action="store_true", help="기존 data.json 유저의 refresh 토큰만 재발급")
    parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    parser.add_argument("--base-url", default=os.environ.get("BASE_URL", DEFAULT_BASE_URL),
                        help="ingress 진입점 (기본 http://localhost). port-forward 쓰면 http://localhost:<port>")
    parser.add_argument("--data-file", type=Path, default=DEFAULT_DATA_FILE)
    parser.add_argument("--refresh-ttl-ms", type=int, default=DEFAULT_REFRESH_TTL_MS)
    parser.add_argument("--seed-tag", default=None)
    return parser.parse_args()


class KindSeed:
    def __init__(self, args: argparse.Namespace) -> None:
        self.ns = args.namespace
        self.base_url = args.base_url.rstrip("/")
        for binary in ("kubectl",):
            if subprocess.run(["which", binary], capture_output=True).returncode != 0:
                raise SeedError(f"'{binary}' 명령을 찾을 수 없다")
        self.pg_user = self._secret("postgres-secret", "POSTGRES_USER")
        self.pg_db = self._secret("postgres-secret", "POSTGRES_DB")
        self.redis_password = self._secret("redis-secret", "REDIS_PASSWORD")

    # ── kubectl helpers ────────────────────────────────────────────────
    def _run(self, command: list[str], stdin: str | None = None) -> str:
        completed = subprocess.run(command, input=stdin, capture_output=True, text=True, check=False)
        if completed.returncode != 0:
            tail = (completed.stderr.strip().splitlines() or ["command failed"])[-1]
            raise SeedError(f"command failed ({completed.returncode}): {' '.join(command[:6])}…; {tail}")
        return completed.stdout

    def _secret(self, name: str, key: str) -> str:
        raw = self._run([
            "kubectl", "-n", self.ns, "get", "secret", name,
            "-o", f"jsonpath={{.data.{key}}}",
        ]).strip()
        if not raw:
            raise SeedError(f"secret {name}/{key} 가 비어있다")
        return base64.b64decode(raw).decode("utf-8")

    def psql(self, sql: str) -> str:
        return self._run([
            "kubectl", "-n", self.ns, "exec", "-i", "deploy/postgres", "--",
            "psql", "-v", "ON_ERROR_STOP=1", "-U", self.pg_user, "-d", self.pg_db, "-tA", "-c", sql,
        ])

    def redis(self, *arguments: str) -> str:
        return self._run([
            "kubectl", "-n", self.ns, "exec", "-i", "deploy/redis", "--",
            "redis-cli", "--no-auth-warning", "-a", self.redis_password, *arguments,
        ])

    def api(self, method: str, path: str, *, token: str | None = None,
            refresh_cookie: str | None = None, body: dict | None = None):
        request = Request(f"{self.base_url}/api/v1{path}", method=method)
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        if refresh_cookie:
            request.add_header("Cookie", f"refresh_token={refresh_cookie}")
        payload = None
        if body is not None:
            payload = json.dumps(body).encode("utf-8")
            request.add_header("Content-Type", "application/json")
        try:
            with urlopen(request, payload, timeout=15) as response:
                raw = response.read() or b"{}"
                return response.status, json.loads(raw), response.headers.get_all("Set-Cookie") or []
        except HTTPError as error:
            return error.code, {}, error.headers.get_all("Set-Cookie") or []
        except URLError as error:
            raise SeedError(f"API 요청 실패: {error.reason}") from error

    # ── seed primitives ───────────────────────────────────────────────
    def seed_redis_token(self, user_id: str, ttl_ms: int) -> tuple[str, str]:
        """identity RedisRefreshTokenStore.save() 와 동일한 키 구조를 직접 만든다."""
        token = new_opaque_token()
        family_id = new_opaque_token()
        token_hash = sha256_hex(token)
        self.redis("SET", f"auth:refresh:token:{token_hash}", f"{user_id}|{family_id}", "PX", str(ttl_ms))
        self.redis("SET", f"auth:refresh:family:{family_id}", token_hash, "PX", str(ttl_ms))
        self.redis("SADD", f"auth:refresh:user:{user_id}", family_id)
        self.redis("PEXPIRE", f"auth:refresh:user:{user_id}", str(ttl_ms))
        return token, family_id

    @staticmethod
    def rotated_cookie(set_cookies: list[str]) -> str | None:
        for header in set_cookies:
            first = header.split(";", 1)[0].strip()
            if first.startswith("refresh_token="):
                return first.split("=", 1)[1] or None
        return None

    def refresh(self, token: str) -> tuple[str, str]:
        status, body, set_cookies = self.api("POST", "/auth/token/refresh", refresh_cookie=token)
        rotated = self.rotated_cookie(set_cookies)
        access_token = body.get("data", {}).get("accessToken") if isinstance(body, dict) else None
        if status != 200 or not isinstance(access_token, str) or not (rotated and len(rotated) >= 20):
            raise SeedError(f"refresh 계약 실패: status {status}")
        return access_token, rotated

    def create_travel(self, access_token: str, index: int) -> str:
        status, body, _ = self.api("POST", "/travels", token=access_token, body={
            "title": f"LoadTest Travel {index}", "startDate": "2026-08-01", "endDate": "2026-08-05",
        })
        travel_id = body.get("data", {}).get("travelId") if isinstance(body, dict) else None
        if status not in (200, 201) or not isinstance(travel_id, str):
            raise SeedError(f"travel 생성 계약 실패: status {status}")
        return travel_id

    def create_timeline_items(self, access_token: str, travel_id: str) -> list[str]:
        item_ids: list[str] = []
        for visit_order in (1, 2, 3):
            status, body, _ = self.api("POST", f"/travels/{travel_id}/timeline-items", token=access_token, body={
                "dayNumber": 1, "visitDate": "2026-08-01", "category": "관광지",
                "name": f"seed-item-{visit_order}", "visitOrder": visit_order,
            })
            item_id = body.get("data", {}).get("timelineItemId") if isinstance(body, dict) else None
            if status not in (200, 201) or not isinstance(item_id, str):
                raise SeedError(f"timeline 생성 계약 실패: status {status}")
            item_ids.append(item_id)
        return item_ids

    @staticmethod
    def write_credentials(payload: dict, path: Path) -> None:
        path = path.resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as tmp:
            tmp_path = Path(tmp.name)
            json.dump(payload, tmp, indent=2, ensure_ascii=False)
            tmp.write("\n")
        tmp_path.chmod(0o600)
        os.replace(tmp_path, path)


def seed_all(runtime: KindSeed, args: argparse.Namespace) -> None:
    seed_tag = re.sub(r"[^A-Za-z0-9-]", "", args.seed_tag or datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))[-18:]
    credentials = []
    for index in range(1, args.users + 1):
        provider_user_id = f"loadtest-{seed_tag}-{index:03d}"
        user_id = str(uuid.uuid4())
        runtime.psql(
            "INSERT INTO identity.user_table "
            "(id, provider, provider_user_id, email, name, nickname, profile_completed, created_at, updated_at) VALUES "
            f"({sql_literal(user_id)}, 'GOOGLE', {sql_literal(provider_user_id)}, "
            f"{sql_literal(provider_user_id + '@loadtest.local')}, {sql_literal('LoadTest ' + str(index))}, "
            f"{sql_literal('load' + seed_tag[-8:] + str(index))}, TRUE, now(), now())"
        )
        refresh_token, family_id = runtime.seed_redis_token(user_id, args.refresh_ttl_ms)
        access_token, refresh_token = runtime.refresh(refresh_token)
        travel_id = runtime.create_travel(access_token, index)
        timeline_ids = runtime.create_timeline_items(access_token, travel_id)
        credentials.append({
            "userId": user_id,
            "travelId": travel_id,
            "refreshToken": refresh_token,
            "refreshFamilyId": family_id,
            "visitDate": "2026-08-01",
            "timelineItemIds": timeline_ids,
        })
        print(f"[seed] user {index}/{args.users} prepared")
    runtime.write_credentials({
        "seedVersion": "s1-kind",
        "seedTag": seed_tag,
        "seededAt": datetime.now(timezone.utc).isoformat(),
        "baseUrl": runtime.base_url,
        "credentials": credentials,
    }, args.data_file)
    print(f"[seed] complete: {len(credentials)} synthetic users -> {args.data_file}")


def refresh_only(runtime: KindSeed, args: argparse.Namespace) -> None:
    path = args.data_file.resolve()
    if not path.exists():
        raise SeedError(f"credential 파일이 없다: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    for credential in payload.get("credentials", []):
        refresh_token, family_id = runtime.seed_redis_token(credential["userId"], args.refresh_ttl_ms)
        credential["refreshToken"] = refresh_token
        credential["refreshFamilyId"] = family_id
    payload["seededAt"] = datetime.now(timezone.utc).isoformat()
    runtime.write_credentials(payload, path)
    print(f"[seed] refresh tokens renewed: {len(payload.get('credentials', []))} users")


def main() -> int:
    args = parse_args()
    if not 1 <= args.users <= 200:
        raise SeedError("--users 는 1~200")
    args.data_file = args.data_file.resolve()
    runtime = KindSeed(args)
    if args.tokens_only:
        refresh_only(runtime, args)
    else:
        seed_all(runtime, args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SeedError as error:
        print(f"[seed] ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
