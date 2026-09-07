# secrets/

실제 비밀값은 Git 에 저장하지 않는다. `*.dev.env` 는 `.gitignore` 되어 있고,
`*.dev.env.example` 만 커밋한다. `scripts/setup.sh` 가 아래 5개 Secret 을
로컬 `*.dev.env` 로부터 생성한다 (재실행 시 최신 값으로 갱신).

## Secret 매트릭스 (Kind PoC)

| Secret | env 파일 | 키 | 참조 대상 |
|---|---|---|---|
| `postgres-secret` | `postgres.dev.env` | `POSTGRES_DB` `POSTGRES_USER` `POSTGRES_PASSWORD` | postgres, identity, community, travel, maps |
| `redis-secret` | `redis.dev.env` | `REDIS_PASSWORD` | redis, identity, maps |
| `jwt-secret` | `jwt.dev.env` | `JWT_SECRET` | identity, community, travel, maps |
| `identity-oauth-secret` | `identity-oauth.dev.env` | `GOOGLE_OAUTH_*` `NAVER_OAUTH_*` | identity |
| `maps-secret` | `maps.dev.env` | `GOOGLE_MAPS_API_KEY` | maps |

`JWT_SECRET` 은 4개 서비스가 동일 값을 공유하는 서명 키라 서비스별 Secret 에 복사하지
않고 `jwt-secret` 하나로 둔다. 발급자 검증(`JWT_ISSUER=identity-service`)은 비민감이라
각 서비스 ConfigMap(`k8s/overlays/kind-dev/backend/<svc>/`)에서 고정한다.

## 수동 생성 예시

```bash
kubectl create secret generic postgres-secret \
  -n travel-planner \
  --from-env-file=secrets/postgres.dev.env
```

## 다음 단계 (EKS)

`kubectl create secret` 은 Kind 전용. EKS 는 External Secrets Operator / SSM
Parameter Store / Sealed Secrets 중 하나로 대체한다. DB 도 서비스별 계정
(`identity_user` → `identity` 스키마만 GRANT)으로 좁히는 것을 재검토한다.
