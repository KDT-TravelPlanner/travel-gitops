# travel-gitops

KDT Travel Diary MSA의 Kubernetes 배포 선언을 관리하는 GitOps 레포입니다.

## 범위

- 대상 환경: Kind 개발 클러스터 (EKS 이전 전 로컬 검증 / 부하 테스트)
- CD 도구: Argo CD (app-of-apps, `argocd/` + `bootstrap/install/`)
- 배포 대상: `identity-service`, `community-service`, `travel-service`, `maps-service`
- `travel-common`은 공통 라이브러리이므로 Kubernetes 배포 대상이 아닙니다.

## 현재 단계

Kind 개발 클러스터용 매니페스트(Kustomize base + `kind-dev` 오버레이) 제공.
배포 경로 2가지:
- **Argo CD** (`argocd/`) — GitOps. `scripts/argocd-bootstrap.sh`
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
  (`k8s/overlays/kind-dev/platform/ingress.yaml` 매핑표). `kind-config.yaml` 에 hostPort 80/443 + `ingress-ready` 라벨 필요
- 4개 서비스가 동일 `JWT_SECRET`(`jwt-secret`) + `JWT_ISSUER=identity-service` 를 공유해 토큰 상호 통용
- 로컬 이미지 검증: `<svc>-service:local`을 `kind load`한다. ECR 검증은
  `k8s/overlays/kind-ecr/`에서 main 릴리스의 immutable digest를 사용한다.
  `kind load docker-image` 로 노드에 주입

## 디렉터리

```text
k8s/
├── base/
│   ├── backend/<service>/     Deployment + Service (환경 무관 공통)
│   └── platform/              Namespace (환경 무관 공통)
└── overlays/kind-dev/
    ├── backend/<service>/     ConfigMap과 Kind 환경값
    ├── platform/              Postgres·Redis·Ingress (Kind 전용)
    └── ingress-nginx/         Kind ingress-nginx 애드온

argocd/
├── project.yaml               배포 권한 범위(AppProject)
├── root-app-kind-dev.yaml     Kind app-of-apps 진입점
└── applications/kind-dev/     platform·서비스·ingress Child Application

clusters/kind-dev/
└── kind-config.yaml           단일 control-plane Kind 클러스터 생성 설정

secrets/
├── README.md                 Secret 매트릭스 (어떤 Secret 을 누가 참조하는지)
└── <name>.dev.env.example     Secret 별 로컬 env 파일 템플릿 (5개)

scripts/
├── build-images.sh           4개 서비스 bootJar → docker build <svc>-service:local
├── setup.sh                  클러스터 생성 → 이미지 로드 → Secret 5개 → apply -k → rollout 대기
├── argocd-bootstrap.sh        Argo CD 최초 설치·연결
├── migrate-argocd-layout.sh   기존 Argo CD root 경로 1회 전환(SCRUM-128)
└── teardown.sh               kind delete cluster
```

`base`에는 어느 환경에서도 같은 서비스 정의를 두고, `overlays/<환경>`에는 DB 주소,
이미지, 외부 진입점처럼 환경에 따라 달라지는 값만 둔다. 따라서 EKS를 추가할 때는
`k8s/overlays/eks-dev/`를 추가해 같은 base를 재사용한다. Argo CD는
`argocd/applications/<환경>/`의 Application이 가리키는 최종 overlay만 동기화한다.

기존 Kind 클러스터에 Argo CD를 이미 설치했다면, SCRUM-128 PR이 `develop`에 머지된 뒤
`./scripts/migrate-argocd-layout.sh`를 한 번 실행해 root Application의 추적 경로를
새 구조로 전환한다. 자세한 내용은 [`argocd/README.md`](argocd/README.md)를 참고한다.

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

### Kind에서 ECR 이미지 검증

`kind-dev`는 기존 로컬 이미지(`kind load`) 흐름을 보존한다. ECR 배포 전환은
`kind-ecr` overlay로 분리한다. 이 방식으로 로컬 개발용 이미지와 실제 레지스트리에서
pull한 이미지를 혼동하지 않는다.

ECR은 private registry이므로, Argo CD가 ECR overlay로 전환되기 전에 아래 명령으로
Kind namespace에 pull Secret을 생성한다. 이 Secret 값은 커밋하지 않으며 ECR 토큰은
약 12시간 후 다시 생성해야 한다.

```bash
./scripts/create-ecr-pull-secret.sh travel-planner
```

현재 SCRUM-137은 Identity를 먼저 ECR overlay로 전환해 검증한다. Community·Travel·Maps는
동일 overlay를 준비했으며 Identity 검증 뒤 Argo Application 경로를 순서대로 전환한다.

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
