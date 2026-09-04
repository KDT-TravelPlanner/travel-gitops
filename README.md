# travel-gitops

KDT Travel Diary MSA의 Kubernetes 배포 선언을 관리하는 GitOps 레포입니다.

## 범위

- 대상 환경: Kind 개발 클러스터 (EKS 이전 전 로컬 검증 / 부하 테스트)
- CD 도구: Argo CD (app-of-apps, `bootstrap/`)
- 배포 대상: `identity-service`, `community-service`, `travel-service`, `maps-service`
- `travel-common`은 공통 라이브러리이므로 Kubernetes 배포 대상이 아닙니다.

## 현재 단계

Kind 개발 클러스터용 매니페스트(Kustomize base + `kind-dev` 오버레이) 제공.
배포 경로 2가지:
- **Argo CD** (`bootstrap/`) — GitOps. `scripts/argocd-bootstrap.sh`
- **수동** — `kubectl apply -k` 직접. `scripts/setup.sh`

이미지 레지스트리 push 는 아직(레지스트리 확정 대기) — `kind load` 수동.

## 아키텍처 (kind-dev)

- 네임스페이스 `travel-planner` 하나에 전부 배포
- **PostgreSQL 1대 공유** — 단일 DB `travel_diary_dev`, 서비스별 스키마
  (`identity` / `community` / `travel` / `maps`)로 경계 분리. 각 서비스 Flyway 가
  자기 스키마를 생성·마이그레이션
- **Redis 1대 공유** — `identity`, `maps` 만 사용 (`community`, `travel` 은 미사용)
- 서비스 간 호출은 k8s Service DNS (`http://identity:8080` 등), 전부 앱 포트 8080 / 관리 포트 9091
- **외부 진입점**: ingress-nginx(Kind provider) — `http://localhost/` 에서 경로로 라우팅
  (`clusters/kind-dev/platform/ingress.yaml` 매핑표). `kind-config.yaml` 에 hostPort 80/443 + `ingress-ready` 라벨 필요
- 4개 서비스가 동일 `JWT_SECRET`(`jwt-secret`) + `JWT_ISSUER=identity-service` 를 공유해 토큰 상호 통용
- 이미지: `<svc>-service:local` (사전 빌드 JAR → 단일 스테이지, `imagePullPolicy: IfNotPresent`),
  `kind load docker-image` 로 노드에 주입

## 디렉터리

```text
clusters/kind-dev/
├── kind-config.yaml           단일 control-plane 노드
├── kustomization.yaml         platform + 4개 서비스 오버레이 집계 (kubectl apply -k 진입점)
└── platform/
    ├── namespace.yaml
    ├── postgres.yaml          PVC + Deployment + Service (로컬 스탠드인, EKS 는 RDS)
    └── redis.yaml             PVC + Deployment + Service (로컬 스탠드인, EKS 는 ElastiCache)

apps/<service>/
├── base/                      Deployment + Service (환경 무관 공통)
└── overlays/kind-dev/         네임스페이스 + configMapGenerator (비민감 env)

secrets/
├── README.md                 Secret 매트릭스 (어떤 Secret 을 누가 참조하는지)
└── <name>.dev.env.example     Secret 별 로컬 env 파일 템플릿 (5개)

scripts/
├── build-images.sh           4개 서비스 bootJar → docker build <svc>-service:local
├── setup.sh                  클러스터 생성 → 이미지 로드 → Secret 5개 → apply -k → rollout 대기
└── teardown.sh               kind delete cluster
```

## 사용법

```bash
# 0. 사전: kind, kubectl, docker. 서비스 레포 4개가 ~/github/<svc>-service 에 있어야 함
#    (다른 위치면 SERVICE_REPOS_DIR 로 지정)
for f in secrets/*.dev.env.example; do cp "$f" "${f%.example}"; done   # 값 채우기 (.gitignore 됨)

# 1. 이미지 빌드
./scripts/build-images.sh

# 2. 클러스터 생성 + 전체 배포
./scripts/setup.sh

# 3. 확인
kubectl get pods -n travel-planner
kubectl port-forward -n travel-planner svc/identity 9091:9091 &
curl localhost:9091/actuator/health/readiness

# 4. 정리
./scripts/teardown.sh
```

## 시크릿

레포에 실제 값을 커밋하지 않습니다. `secrets/*.dev.env` (gitignore) 에서
`kubectl create secret ... --from-env-file` 로 로컬 생성하며, `setup.sh` 가 자동으로
처리합니다 (재실행 시 최신 값으로 갱신).

용도별로 5개 Secret 으로 나눠 최소 권한으로 주입합니다 — 자세한 매트릭스는
[`secrets/README.md`](secrets/README.md).

| Secret | 참조 대상 |
|---|---|
| `postgres-secret` | postgres, identity, community, travel, maps |
| `redis-secret` | redis, identity, maps |
| `jwt-secret` | identity, community, travel, maps (공유 서명 키) |
| `identity-oauth-secret` | identity |
| `maps-secret` | maps |

발급자 검증값 `JWT_ISSUER=identity-service` 는 비민감이라 각 서비스 ConfigMap 에
고정합니다 (`JWT_SECRET` 공유만으로는 부족하고 issuer 도 일치해야 함).

## 프로덕션 인프라와의 관계

이 안의 PostgreSQL / Redis 는 **로컬 전용 스탠드인**입니다. 프로덕션/EKS 는 RDS 와
ElastiCache 를 쓰며 이 매니페스트가 그대로 올라가지 않습니다.

## 다음 단계

- **이미지 레지스트리 push** — 레지스트리(ECR) 확정 → CI push → Argo 가 태그 감지
- **HPA / PDB** (부하 테스트 단계) — HPA 붙일 때 서비스 Application 에
  `ignoreDifferences: /spec/replicas` 를 넣어야 Argo selfHeal 과 안 싸운다
- Grafana/Prometheus 등 관측 스택 (모놀리스 `compose.monitoring.*` 참고)
