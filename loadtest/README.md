# loadtest/

MSA(Kind) 부하·기능 테스트용 합성 데이터 시드. 모놀리스 `KDT_TravelDiary/load-tests/`
방식을 최대한 그대로 따른다.

```
loadtest/
├── seed-kind-load-data.py     합성 사용자 + refresh token + Travel/Timeline 시드
└── data/
    ├── data.json.example      k6 가 읽는 credential 파일 형식 (예시)
    └── data.json              실제 시드 결과 (gitignore — refresh token 실값 포함)
```

## 인증 방식 — 왜 "가짜 JWT" 를 안 만드나

모놀리스와 동일하게, **테스트 전용 백엔드 엔드포인트를 추가하지 않고 실제 계약을 쓴다**:

```
1. identity.user_table 에 합성 사용자 INSERT
2. Redis 에 refresh-token family 를 직접 심는다 (identity RedisRefreshTokenStore 와 같은 키 구조)
     auth:refresh:token:<sha256hex(token)>  = "<userId>|<familyId>"
     auth:refresh:family:<familyId>          = <sha256hex(token)>
     auth:refresh:user:<userId>              ∋ <familyId>
3. POST /api/v1/auth/token/refresh (ingress 경유) → identity 가 진짜 access token 발급 + refresh 회전
4. 그 access token 으로 Travel 1개 + Timeline 3개 생성
5. data/data.json 에 {userId, travelId, refreshToken, refreshFamilyId, timelineItemIds} 기록 (0600)
```

→ access token 은 **identity 가 실제로 서명·발급한 것** (`iss=identity-service`, 정확한 claim/만료).
`mint_token.py`(msa-local) 처럼 위조하지 않는다. OAuth 코드 교환·consent 화면만 건너뛴다.

refresh token 은 회전되므로 부하 단계마다 재시드한다 (`--tokens-only` 는 유저는 두고 토큰만).

## 모놀리스와 다른 점

| | 모놀리스 `seed-compose-load-data.py` | 여기 `seed-kind-load-data.py` |
|---|---|---|
| 접근 | `docker compose exec postgres/redis` | `kubectl -n travel-planner exec deploy/postgres`,`deploy/redis` |
| 자격증명 | `--env-file .env.prod.example` 파싱 | 클러스터 Secret(`postgres-secret`,`redis-secret`)에서 읽음 |
| user 테이블 | `user_table` | `identity.user_table` (스키마) |
| base URL | `http://127.0.0.1:18080` | `http://localhost` (ingress) |

키 구조·해시(sha256 hex)·회전 계약·data.json 형식은 동일.

## 사용법

사전: Kind 클러스터 실행 중 + ingress(`http://localhost`) 접근 가능.

```bash
# 합성 사용자 20명 시드
./loadtest/seed-kind-load-data.py --users 20

# 부하 단계 사이 — 유저 유지, refresh 토큰만 재발급
./loadtest/seed-kind-load-data.py --tokens-only

# port-forward 로 접근하는 경우
./loadtest/seed-kind-load-data.py --base-url http://localhost:18080
```

## 다음 (미이식)

모놀리스 `load-tests/k6/` 전체 프레임워크 — 시나리오(baseline/spike/recovery),
`lib/auth.js`(위 data.json 소비), SLO gate, evidence 수집 — 는 아직 안 옮겼다.
`lib/auth.js` 는 `TOKEN_MODE=refresh` 로 이 data.json 을 거의 그대로 소비하므로,
k6 시나리오 이식 시 base URL 만 ingress 로 바꾸면 된다.
