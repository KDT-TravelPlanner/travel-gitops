# SCRUM-127 — dev / dev-eks Terraform 이관

`KDT_TravelDiary`의 persistent `dev`와 disposable `dev-eks` 환경을 이 저장소로 복제했다.
원본 파일은 수정하지 않았다. 이관 검증은 기존 AWS 리소스 주소 및 원격 state를 유지한다.
이전 ECR-only `msa/dev/terraform.tfstate` 안내와 plan은 이 구성을 적용하는 데 사용하지 않는다.

## 구성

- `environments/dev/main.tf`: 기존 VPC·subnet·route table, frontend S3/CloudFront,
  profile-image S3/CloudFront/runtime IAM, ACM 인증서, backend application Secret,
  기존 backend ECR 및 GitHub publisher/frontend deployer, **4개 MSA ECR/publisher 추가**.
- `environments/dev-eks/`: private EKS·node group·IRSA OIDC, NAT·routes, RDS/Redis,
  Pod Identity, SSM bastion, Monitoring EC2, private DNS, 배포 snapshot/contract.
- `environments/dev/oidc.tf`: 공용 GitHub OIDC provider를 소유한다. 기존 모듈 내부 주소는 `moved` 블록으로 이동해 AWS 리소스를 보존한다.
- `modules/github_ecr_publisher`: 기존 모놀리스와 서비스 4개가 공유하는 publisher 구현이다.
  필수 `github_oidc_provider_arn`과 선택적 `service_name`을 받고 각 저장소의 ECR에만 push 권한을 부여한다.
  기존 `module.github_ecr_publisher` 및 `module.service_github_ecr_publisher` 호출 주소는 유지한다.
- `k8s/base`, `k8s/overlays/dev-eks`, `scripts/eks`의 배포 bundle 스크립트,
  `monitoring/`: dev-eks Terraform이 파일로 참조하는 원본 의존성도 함께 복제했다.
  SCRUM-81에서 기본 dev-eks를 MSA로 전환했다. 이전 backend baseline은 dev-eks-monolith에 보존한다.

`travel-common`은 JAR 라이브러리이므로 컨테이너 저장소를 만들지 않는다.

## State와 원본 보존

동일 계정/버킷에서 `dev/terraform.tfstate`, `dev-eks/terraform.tfstate`를 사용한다.
`dev-eks`의 `persistent_state_key`는 `dev/terraform.tfstate`다.
backend 암호화 및 S3 native lock을 켠다. **새 빈 state로 기존 dev 리소스를 중복 생성하지 않는다.**
기존 publisher 모듈 호출 주소는 보존한다. OIDC provider 주소 이동은 선언적 `moved` 블록으로 처리하므로 수동 import/state mv나 backend migration은 필요하지 않다.
원본과 이 복제본을 동시에 운영하는 별도 소유자로 취급하면 안 된다. 이후 변경은 이 저장소를
기준으로 검토하며, 원본 디렉터리에서 독립적으로 apply하면 MSA 리소스 삭제 plan을 만들 수 있다.
이번 작업은 validate/plan 검증까지만 수행한다.

## 검증 명령

```bash
export AWS_PROFILE=kdt-travel-terraform
aws sts get-caller-identity

# 실제 값은 Git에서 제외한다. 처음 사용하는 경우 example을 복사하고 값을 입력한다.
terraform -chdir=infra/environments/dev init -reconfigure -input=false -backend-config=backend.hcl
terraform -chdir=infra/environments/dev validate
terraform -chdir=infra/environments/dev plan -input=false -out=dev.tfplan

# dev-runtime 및 dev-load-test의 원격 state가 비어 있는지 먼저 확인한다.
terraform -chdir=infra/environments/dev-eks init -reconfigure -input=false -backend-config=backend.hcl
terraform -chdir=infra/environments/dev-eks validate
terraform -chdir=infra/environments/dev-eks plan -input=false -out=dev-eks.tfplan
```

`-reconfigure`는 로컬 backend 연결을 갱신하며 state를 복사하는 `-migrate-state`와 다르다.
[Terraform init 공식 문서](https://developer.hashicorp.com/terraform/cli/commands/init)

각 환경의 `terraform test`는 mock provider와 plan 명령으로 검증한다.
저장된 plan/JSON과 실제 tfvars/backend 설정은 커밋하지 않는다.

## GitHub OIDC / MSA 이미지 publish

GitHub provider는 `dev/oidc.tf`가 소유하고 기존 publisher·서비스 4개 publisher·frontend deployer에 ARN을 전달한다.
서비스 role은 `repo:protove@114971169/<service>-service@<repositoryId>:environment:dev` 및
`aud=sts.amazonaws.com`을 정확히 요구한다. EKS 자체 OIDC provider와는 별도 리소스다.

apply 후 `terraform output github_environment_variables`로 각 서비스의 값을 확인한다.
GitHub dev Environment에 `AWS_REGION`, `ECR_REPOSITORY_URL`, `AWS_ECR_PUBLISH_ROLE_ARN`을 넣고,
publish job에는 `environment: dev`, `permissions: {contents: read, id-token: write}`를 지정한다.
태그는 commit SHA, 배포 식별자는 ECR digest를 사용한다.
이관 시점에 서비스의 dev Environment 및 ECR push job은 아직 연결되지 않았으므로
Terraform plan을 실제 STS assume 또는 Docker push 성공으로 해석하지 않는다.

[GitHub OIDC 공식 문서](https://docs.github.com/en/actions/reference/security/oidc)
