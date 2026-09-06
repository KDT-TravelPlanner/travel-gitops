# infra/

MSA 서비스용 AWS 인프라 (Terraform). 지금 범위는 **서비스별 ECR + GitHub Actions OIDC
push Role** 뿐이다. 모놀리스 `KDT_TravelDiary/infra/` 의 `container_registry` +
`github_ecr_publisher` 패턴을 그대로 따른다.

```
infra/
├── modules/
│   ├── service_ecr/            ECR 저장소 1개 (IMMUTABLE 태그, scan-on-push, lifecycle)
│   └── github_ecr_publisher/   OIDC 로 assume 하는 push 전용 IAM Role 1개
└── environments/
    └── dev/                    위 모듈을 서비스 4개(identity/community/travel/maps)로 호출
```

travel-common 은 컨테이너가 아니라 JAR(GitHub Packages) 라 ECR 없음.

## 모놀리스와 같은 점

- ECR: `IMMUTABLE` 태그, push 시 취약점 스캔, AES256, lifecycle(untagged 7일 삭제 + 롤백용 최신 20개 유지)
- Role trust: `repo:protove@<ownerId>/<repo>@<repoId>:environment:dev` — repo/owner 를 **숫자 ID** 로 고정
- Role policy: `ecr:GetAuthorizationToken` 은 `*`, 나머지 push/describe 는 해당 저장소 ARN 하나로 제한
- `max_session_duration = 3600`
- 태그 = `github.sha`, 실제 배포 식별자는 `aws ecr describe-images` 로 조회한 digest

## 모놀리스와 다른 점

| | 모놀리스 | 여기 |
|---|---|---|
| 저장소 | 1개 (`...-dev-backend`) | 4개 (`...-dev-{identity,community,travel,maps}`) |
| GitHub 레포 | 1개 | 4개 각각 → OIDC subject 4개 |
| OIDC provider | 모듈이 생성 | 계정당 1개 싱글턴 — 기본은 **기존 것 참조**(`data`), `manage_github_oidc_provider=true` 면 생성 |
| tfstate | 같은 S3 버킷 | 같은 버킷, key 만 `msa/dev/terraform.tfstate` 로 분리 |

## 적용 방법

사전: `aws` 자격증명(대상 계정), Terraform >= 1.10.

```bash
cd infra/environments/dev
cp terraform.tfvars.example terraform.tfvars   # aws_account_id 등 채우기

terraform init \
  -backend-config="bucket=<모놀리스와 동일한 tfstate 버킷>" \
  -backend-config="key=msa/dev/terraform.tfstate" \
  -backend-config="region=ap-northeast-2"

terraform plan     # OIDC provider 를 만들 건지(count) 먼저 확인
terraform apply
```

`manage_github_oidc_provider` 판단:

```bash
aws iam list-open-id-connect-providers   # token.actions.githubusercontent.com 있으면 false(기본), 없으면 true
```

## apply 후 — 서비스 레포에 GitHub Environment 변수 설정

`terraform output github_environment_variables` 가 서비스별로 뽑아준다. 각 서비스 레포
(`protove/<svc>-service`) → Settings → Environments → `dev` 에:

| 변수 | 값 |
|---|---|
| `AWS_REGION` | `ap-northeast-2` |
| `ECR_REPOSITORY_URL` | `<account>.dkr.ecr.ap-northeast-2.amazonaws.com/kdt-travelplanner-dev-<svc>` |
| `AWS_ECR_PUBLISH_ROLE_ARN` | `arn:aws:iam::<account>:role/kdt-travelplanner-dev-<svc>-ecr-publisher` |

그다음 각 서비스 `build.yml` 에 push job 추가 (모놀리스 `backend-deploy-dev.yml` 참고):
OIDC assume → `aws ecr get-login-password` → `docker build --push tags=$ECR_REPOSITORY_URL:${github.sha}`
→ `aws ecr describe-images` 로 digest → travel-gitops 오버레이의 이미지 참조를 그 digest 로 갱신.

## 테스트

```bash
terraform -chdir=infra/modules/service_ecr test
terraform -chdir=infra/modules/github_ecr_publisher test
terraform -chdir=infra/environments/dev test    # mock provider, plan-only
```
