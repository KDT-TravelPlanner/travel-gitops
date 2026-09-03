# travel-gitops

KDT Travel Diary MSA의 Kubernetes 배포 선언을 관리하는 GitOps 레포입니다.

## 범위

- 대상 환경: Kind 개발 클러스터 (EKS 이전 전 로컬 검증 / 부하 테스트)
- CD 도구: Argo CD (다음 단계 — 아직 미구성)
- 배포 대상: `identity-service`, `community-service`, `travel-service`, `maps-service`
- `travel-common`은 공통 라이브러리이므로 Kubernetes 배포 대상이 아닙니다.

## 현재 단계

Kind 개발 클러스터용 매니페스트(Kustomize base + `kind-dev` 오버레이)와 로컬
셋업 스크립트를 제공합니다. `kubectl apply -k` 로 직접 배포하며, Argo CD Application
sync 는 아직 붙이지 않았습니다 (`bootstrap/` 는 그 단계에서 채웁니다).

## 아키텍처 (kind-dev)

- 네임스페이스 `travel-planner` 하나에 전부 배포
- **PostgreSQL 1대 공유** — 단일 DB `travel_diary_dev`, 서비스별 스키마
  (`identity` / `community` / `travel` / `maps`)로 경계 분리. 각 서비스 Flyway 가
  자기 스키마를 생성·마이그레이션
- **Redis 1대 공유** — `identity`, `maps` 만 사용 (`community`, `travel` 은 미사용)
- 서비스 간 호출은 k8s Service DNS (`http://identity:8080` 등), 전부 앱 포트 8080 / 관리 포트 9091
- 4개 서비스가 동일 `JWT_SECRET` + `JWT_ISSUER=travel-planner-backend` 를 공유해 토큰 상호 통용
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
├── travel-planner-secret.example.yaml   필요한 키 목록 (문서용, 값 없음)
└── .env.kind-dev.example                로컬 env 파일 템플릿

scripts/
├── build-images.sh           4개 서비스 bootJar → docker build <svc>-service:local
├── setup.sh                  클러스터 생성 → 이미지 로드 → secret → apply -k → rollout 대기
└── teardown.sh               kind delete cluster
```

## 사용법

```bash
# 0. 사전: kind, kubectl, docker. 서비스 레포 4개가 ~/github/<svc>-service 에 있어야 함
#    (다른 위치면 SERVICE_REPOS_DIR 로 지정)
cp secrets/.env.kind-dev.example secrets/.env.kind-dev   # 값 채우기 (.gitignore 됨)

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

레포에 실제 값을 커밋하지 않습니다. `secrets/.env.kind-dev` (gitignore) 에서
`kubectl create secret ... --from-env-file` 로 로컬 생성하며, `setup.sh` 가 자동으로
처리합니다 (재실행 시 최신 값으로 갱신). `postgres` / `redis` / 4개 서비스가
`travel-planner-secret` 하나를 공유하고 각자 필요한 키만 `secretKeyRef` 로 참조합니다.

## 프로덕션 인프라와의 관계

이 안의 PostgreSQL / Redis 는 **로컬 전용 스탠드인**입니다. 프로덕션/EKS 는 RDS 와
ElastiCache 를 쓰며 이 매니페스트가 그대로 올라가지 않습니다.

## 다음 단계

- Argo CD Application / AppProject (`bootstrap/`, `clusters/kind-dev/platform/`)
- ingress-nginx (현재는 `kubectl port-forward` 로 충분)
- HPA / PDB (부하 테스트 단계에서)
