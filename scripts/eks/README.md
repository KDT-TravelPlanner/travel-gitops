# SCRUM-81 — MSA EKS 배포 계약

현재 상태: **설정 구현 / 실제 이미지·EKS 배포 검증 대기**. Argo CD와 서비스 CI/CD는 범위 밖이다.
실행 서비스는 identity/community/maps/travel이며 travel-common은 빌드 의존성 JAR이다.

## 입력 준비

1. persistent `dev`의 서비스별 ECR/OIDC outputs가 적용되어 있어야 한다.
2. `dev-eks` Terraform plan에서 새 identity Pod Identity, ECR 조회 권한, source bundle,
   Monitoring EC2 대시보드, 노드 타입을 검토한다. 기존 실제 tfvars가 t3.medium을 명시하면 기본값 t3.large를 덮어쓰므로 수정 필요 여부를 확인한다.
3. 계약 `runtime-contract.json`은 Terraform output `deployment_contract_s3_key`에 있는 v2 메타데이터다.
   `service_ecr_repository_urls`는 정확히 identity/community/maps/travel 4개를 포함한다.
   Redis는 TLS 인증서와 일치하는 실제 primary endpoint를 사용한다. Secret 값은 계약에 넣지 않는다.
4. `msa-values.example.json`을 작업용 파일로 복사하고 vpc/subnets/certificate를 계약과 일치시킨다.
   실제 API·frontend HTTPS origin과 서비스별 `<ECR URL>@sha256:<64 hex>`를 입력한다.
   이미지 digest는 팀원 CI/CD 검증 및 push 이후 입력하며, 예제는 배포할 수 없다.
5. S3에서 번들 manifest/contract를 받고 SHA-256을 확인한 후 해당 revision의 runner를 사용한다.
   Bastion에는 aws/jq/kubectl/python3/openssl/sha256sum이 필요하다. PyYAML은 운영 runner에는 불필요하다.

## 단계별 실행 (Bastion)

### 로컬 통합 오케스트레이터 (권장)

`deploy-dev-eks-msa.py`는 실제 변경 전후를 명확히 나눈다. `plan`은 AWS 읽기와 로컬
검증만 수행하고 `review.json`, 저장 plan, plan JSON, 검증 로그를 Git 제외 디렉터리에 만든다.
이 단계에서 다음 조건을 fail-closed로 검사한다.

- 호출 계정, `dev-runtime`/`dev-load-test` 원격 State의 실제 존재 및 managed resource 0개
- identity/community/maps/travel ECR의 최신 **태그된** 이미지 digest
- `terraform fmt -check`, `init`, `validate`, mock `test`, 저장 plan
- delete/replace 0개, 현재 admin SSO 원본 IAM role을 저장 plan의 EKS Access Entry로 고정,
  `t3.large` 2/2/4 node group

```bash
python3 scripts/eks/deploy-dev-eks-msa.py plan \
  --profile kdt-travel-admin \
  --expected-account-id '<AWS account>' \
  --artifact-dir .local/dev-eks-msa-review \
  --backend-hostname api.example.com \
  --backend-origin https://api.example.com \
  --frontend-origin https://example.com
```

출력된 `review.json`, `terraform-plan.log`, `dev-eks.tfplan.json`을 검토한다. 실제 변경은
출력된 두 SHA를 명시해야만 시작된다. `apply`는 **검토된 저장 plan만** Terraform에 적용하고,
비민감 values를 private monitoring bucket에 올린 뒤 SSM Run Command로 배스천에서
`prepare → namespace-secret → platform → workload → ingress-wait`를 실행한다.

```bash
python3 scripts/eks/deploy-dev-eks-msa.py apply \
  --profile kdt-travel-admin \
  --expected-account-id '<AWS account>' \
  --review-file .local/dev-eks-msa-review/review.json \
  --confirm-review-sha256 '<plan 출력값>' \
  --confirm-plan-sha256 '<plan 출력값>'
```

Secret 원문은 오케스트레이터가 읽거나 SSM 인자로 전달하지 않는다. 배스천 instance role이
Secrets Manager에서 읽고 서비스별 Secret을 server-side apply한다. 단계별 SSM invocation은
`apply-evidence/`에 로컬 저장된다. 특정 단계까지만 실행하려면 `--through-stage`를 사용한다.
실패 후에는 같은 review/plan을 무조건 재적용하지 말고 Terraform 및 runner 상태를 먼저 확인한다.

SSM은 command ID를 전송 직후 기록하고 `Pending/InProgress/Delayed` 동안 계속 기다린다.
원격 실행 제한은 4시간, 로컬 대기는 4시간 2분이며 실제 단계의 rollout 제한은 별도로 적용된다.
로컬 대기 만료는 원격 실패로 단정하지 않는다. 기록된 command ID를 조회한 뒤 재개 여부를 판단한다.
과거 버전의 `SSM stage failed`와 함께 JSON이 `InProgress`라면 기본 CLI waiter가 먼저 끝났을 수 있다.
이 경우 Terraform apply나 workload를 다시 전송하지 말고 해당 SSM 명령의 최종 상태를 확인한다.

### SCRUM-81: creator admin Access Entry 409 복구

신규 클러스터는 `bootstrap_cluster_creator_admin_permissions = false`로 만들고
Terraform의 `aws_eks_access_entry.admin`과 정책 연결이 관리자 권한을 소유한다.
과거 `true`로 생성된 클러스터는 생성 전용 필드만 `ignore_changes`로 유지한다.
이 필드를 기존 클러스터에서 변경하면 replacement가 발생하므로 클러스터를 재생성하지 않는다.

부분 apply 후에는 **새 artifact 디렉터리로 plan을 다시 실행**한다. plan은 Terraform State의
클러스터를 기준으로 EKS Entry와 정책 연결을 조회하고, AWS에는 있지만 State에는 없는
현재 SSO admin 리소스를 `access-imports.tf`의 import 블록에 전달한다. 읽기 실패는 중단한다.
`access-imports.json` 및 `review.json`에 import 대상이 기록되며, 실제 State 반영은
새 저장 plan을 apply할 때만 수행한다. Entry를 삭제하거나 별도 `terraform import`할 필요가 없다.
이미 State가 소유한 Entry는 다시 import하지 않는다.

```bash
# travel-gitops 저장소 루트에서 실행. 이전 실패 로그/plan은 보존한다.
python3 scripts/eks/deploy-dev-eks-msa.py plan \
  --profile kdt-travel-admin --expected-account-id 419496180357 \
  --artifact-dir .local/dev-eks-msa-recovery-next \
  --backend-hostname api.kdt-travelplanner.protove.net \
  --backend-origin https://api.kdt-travelplanner.protove.net \
  --frontend-origin https://kdt-travelplanner.protove.net
```

새 plan에서 admin Entry/정책 import, 클러스터 delete/replace 0개를 확인한다.
위 `apply` 명령의 review 경로와 두 SHA를 **새 출력값**으로 바꿔 실행하면
import와 남은 Terraform 작업 이후 배스천의 5단계를 진행한다. 실패한 과거 saved plan은
부분 적용으로 State가 변경됐으므로 재사용하지 않는다. 최초 실패가 Terraform 단계였다면
자동화는 SSM/Secret/Pod 단계에 진입하지 않았으므로 `prepare`부터 실행하는 것이 맞다.
기존 실제 tfvars의 admin 목록이 비어 있을 수 있으므로, 현재 SSO role을 주입하는 이
오케스트레이터를 사용한다. 별도 raw Terraform 명령에는 동일 admin 목록이 필요하다.

이 절차의 완료 범위는 Terraform과 Pod rollout/ALB hostname까지다.
DNS, 실제 로그인/API 동작, DB/Redis, Loki/Prometheus 수신 검증은 배포 후 확인한다.

### 배스천 runner 직접 실행

아래 값을 실제 비민감 metadata로 설정한다. AWS 자격증명은 instance role을 사용한다.

```bash
bundle_revision='<Terraform monitoring_bundle_revision_sha256 output>'
contract_sha='<Terraform deployment_contract_sha256 output>'
values_sha="$(sha256sum /private/work/msa-values.json | awk '{print $1}')"
bucket='<Terraform monitoring bucket output>'
for stage in prepare namespace-secret platform workload ingress-wait; do
  bash scripts/eks/run-dev-eks-deployment.sh \
    --stage "$stage" --bucket "$bucket" \
    --values-file /private/work/msa-values.json \
    --expected-bundle-revision "$bundle_revision" \
    --expected-contract-sha256 "$contract_sha" \
    --expected-values-sha256 "$values_sha" \
    --expected-account-id '<AWS account>' --expected-region ap-northeast-2 \
    --work-dir /var/tmp/travel-planner-dev-eks-msa
 done
```

- `prepare`: manifest 파일 hash 검증, EKS 접속, 독립 렌더링, ECR linux/amd64 image 검증.
- `namespace-secret`: 공유 namespace 및 서비스별 Secret 준비. 자격증명은 프로세스 인자로 넘기지 않는다.
- `platform`: AWS Load Balancer Controller, metrics-server, cluster-autoscaler 기동 확인.
- `workload`: 4개 서비스/Alloy 배포, 모든 replica의 updated/ready/available 및 digest, HPA identity 1–4, 나머지 2–4 확인.
- `ingress-wait`: ALB hostname 출력. DNS/HTTPS 실제 API 검증은 이 단계 이후 별도로 수행한다.

후속 단계는 bundle을 다시 검증·렌더링하고 prepare 당시 values/contract/render hash와 비교한다.
값이 바뀌면 prepare부터 새 work-dir에서 시작한다. 중간 단계 실패를 성공으로 기록하지 않는다.
기존 모놀리스와 MSA가 동시에 같은 API ALB 경로를 소유해서는 안 된다. 현재 신규 클러스터 전제로 구성했다.

## Secret 계약

`prepare`의 이미지 검증은 ECR manifest와 image config를 읽는다. ECR blob 응답이
서명된 S3 URL로 이동할 때 registry Authorization 헤더는 전달하지 않는다.
과거 코드의 `MSA image preflight failed` / blob HTTP 400은 이 헤더가 전달되어
S3에서 인증 방식 중복으로 거부된 사례다. 수정된 runtime은 새 Terraform plan/apply로
S3 bundle에 반영해야 한다. 로컬 파일만 고치고 기존 bundle의 prepare를 재실행하면
같은 오류가 발생한다. Terraform 성공 후의 실패라면 이미 적용된 saved plan을 재사용하지 않는다.

| 서비스 | 주입 키 |
|---|---|
| 공통 | SPRING_DATASOURCE_USERNAME, SPRING_DATASOURCE_PASSWORD, JWT_SECRET |
| identity 추가 | SPRING_DATA_REDIS_PASSWORD, GOOGLE_OAUTH_CLIENT_ID/SECRET, NAVER_OAUTH_CLIENT_ID/SECRET |
| maps 추가 | SPRING_DATA_REDIS_PASSWORD, GOOGLE_MAPS_API_KEY |

Secret 이름은 `<service>-secret`. 현재 RDS master secret을 공유하되 스키마는 identity/community/location/travel로 나눈다.
서비스별 DB 사용자 권한 분리와 기존 모놀리스 데이터 이관은 후속 범위다.
OAuth callback은 identity, Maps 외부 API 키는 maps만 받는다. identity만 S3 Pod Identity 권한을 받는다.

## 가용성·관측

앱 7개 Pod requests: 2100m / 5824Mi (앱+sidecar). 레포에서 정의한 플랫폼/모니터링까지,
노드 2개 기준 약 2950m / 7356Mi다. AWS CNI, CoreDNS, kube-proxy, Pod Identity agent와 kubelet 예약분은 별도다.
기본 2 x t3.large, node max=4. identity HPA 1–4, 나머지 HPA 2–4, CPU target 60%는 앱 container만 측정한다.
서비스별 maxSurge=1이므로 동시 rollout/HPA 최대 replica에는 추가 노드가 필요할 수 있다.
실제 allocatable/스케줄링 및 부하에 따른 조정은 EKS 단계에서 검증하며 최대 부하 수용을 보장하지 않는다.

Alloy sidecar는 ECS JSON 파일 로그만 Loki로 전달한다. 로그 라벨은 service/environment/level만 유지한다.
Pod 단위 로그 영구 보존은 Loki에 의존하며 emptyDir 로그·positions는 Pod 삭제 시 소실된다.
DaemonSet은 자기 노드의 actuator/Pod·kubelet만 수집한다. 단일 alloy-common은 kube-state-metrics를 수집한다.
Grafana `SCRUM-81 EKS MSA`는 서비스·Pod 선택, 요청/오류/p95/JVM/pool/restart/HPA/로그를 제공한다.

```bash
python3 monitoring/verify-msa-observability.py \
  --prometheus-url http://monitoring.dev-eks.kdt-travelplanner.internal:9090 \
  --loki-url http://monitoring.dev-eks.kdt-travelplanner.internal:3100 \
  --output /private/work/msa-observability.json
```

identity는 1개 이상, 나머지 서비스는 2개 이상의 신선한 UP target과 로그를 요구한다.
이는 최소 구성 관측 검사이며 scale-out 이후 전체 Pod 관측 여부는 실제 replica 수와 별도 대조한다. 누락/중복/오래된 증거/민감 라벨은 실패한다.
이 도구는 기능 smoke를 대신하지 않는다. 로그인→여행→지도→커뮤니티 호출, DB/Flyway, Redis TLS,
identity S3 권한, sidecar readiness와 재시작 횟수, ALB health, HPA 부하·롤백을 별도로 검증한다.

## 롤백

성공한 workload 단계는 `$WORK_DIR/releases/<bundle-sha>/<values-sha>/`에 values, contract,
runner-state와 원본 bundle을 보관한다. Secret 값은 포함하지 않는다.

1. 동일 클러스터의 이전 성공 release 디렉터리를 선택한다. 해당 기록의 contract/values/render SHA를 확인한다.
2. **보관된 bundle 안의 runner**를 실행하고 `--bundle-source <release>/bundle`을 추가한다.
3. `--values-file <release>/values.json`, 기록된 SHA, 새 `--work-dir`로 prepare부터 전체 단계를 다시 수행한다.
4. 이 방식은 이전 4개 이미지와 동일한 manifests를 함께 복원한다. Secret은 현재 Secrets Manager 값을 사용한다.
   DB 스키마와 Secret의 역호환성이 확보되지 않은 버전은 자동 롤백 대상이 아니다.
5. Bastion 교체/삭제 시 로컬 release도 사라진다. 장기 보관은 운영자가 해당 비민감 기록을 별도 보관해야 한다.

모놀리스 재배포는 `run-dev-eks-monolith-deployment.sh`와 `dev-eks-monolith`를 명시적으로 사용한다.
MSA→모놀리스 전환은 데이터·ALB 소유권을 검토하는 별도 작업이다.

## dev-eks 삭제 자동화 (로컬 → Bastion → Terraform)

`destroy-dev-eks-msa.py`는 **dev-eks 환경 전체**를 정리한다. 앱만 중지하는 명령이 아니다.
대상은 `infra/environments/dev-eks`, default workspace의 `dev-eks/terraform.tfstate`로 고정한다.
EKS/노드, Bastion, RDS, Redis, Monitoring EC2와 해당 환경의 NAT·네트워크 리소스 등이
저장 destroy plan에 따라 삭제된다. persistent `dev`의 VPC/ECR/프로필 이미지 버킷은
이 State의 관리 대상이 아니므로 유지된다. 정확한 목록은 `review.json`의 `delete_addresses`에서 확인한다.

**현재 RDS 설정은 `skip_final_snapshot=true`, Monitoring 버킷은 `force_destroy=true`다.**
필요한 DB 데이터, Grafana/Loki/Prometheus 데이터와 Bastion release 기록은 먼저 별도로 보관한다.
이 스크립트는 백업이나 외부 DNS 레코드 정리를 수행하지 않는다.

저장소 루트에서 실행하며 로컬에 AWS CLI/Terraform/Python 3, 로그인된 지정 프로필이 필요하다.
private EKS 정리는 기존 SSM Bastion에서 수행하므로 Bastion의 SSM Online 상태,
aws/kubectl/python3/bash와 EKS 접근 권한, 동작 중인 AWS Load Balancer Controller가 필요하다.
로컬 프로필에는 State 접근, Terraform 삭제, SSM 실행 및 ELBv2 목록·태그 조회 권한이 필요하다.

```bash
python3 scripts/eks/destroy-dev-eks-msa.py plan \
  --profile kdt-travel-admin \
  --expected-account-id '<AWS account>' \
  --artifact-dir .local/dev-eks-msa-destroy-20260909
```

`plan`은 AWS/Kubernetes 리소스를 변경하지 않고 로컬 Terraform init 및 읽기·계획 작업을 수행한다.
새 artifact 디렉터리만 허용하며 `review.json`, `cleanup.sh`, `dev-eks-destroy.tfplan`,
plan JSON과 로그를 만든다. plan/JSON에는 민감값이 포함될 수 있으므로 `.local/` 아래에 보관하고
공유하거나 커밋하지 않는다. delete/no-op 이외의 managed resource 작업은 거부한다.

검토 후 출력된 review/plan SHA를 모두 지정한다. **이 명령부터 실제 삭제가 시작된다.**

```bash
python3 scripts/eks/destroy-dev-eks-msa.py apply \
  --profile kdt-travel-admin \
  --expected-account-id '<AWS account>' \
  --review-file .local/dev-eks-msa-destroy-20260909/review.json \
  --confirm-review-sha256 '<plan 출력값>' \
  --confirm-plan-sha256 '<plan 출력값>'
```

실행 순서:

1. 계정·region·backend·default workspace·State lineage/serial·파일 SHA와 저장 plan의 삭제 목록을 재검증한다.
2. SSM으로 `travel-planner/msa` Ingress를 삭제하고 finalizer 처리가 끝날 때까지 기다린다.
   클러스터에 다른 Ingress(모놀리스 포함)나 LoadBalancer Service가 있으면 삭제 전에 중단한다.
3. TargetGroupBinding이 없는지, 클러스터 소유 태그가 붙은 ALB/Target Group이 사라졌는지 확인한다.
   Controller/finalizer나 ALB 삭제 보호 문제를 강제로 우회하지 않는다.
4. 검토한 **저장 destroy plan만** 적용한다. Kubernetes 플랫폼을 먼저 지우지 않으므로
   Load Balancer Controller가 외부 리소스를 정리할 기회를 유지한다.
5. State managed instance 0개, 후속 destroy plan의 삭제 0개와 ELB 잔여물을 확인하고
   `apply-evidence/result.json`에 성공을 기록한다. 이는 태그 없는 수동 리소스까지 전수 검사하는 것은 아니다.

SSM command ID/결과, Terraform 실행 로그, 후속 plan과 ELB 조회 결과는 `apply-evidence/`에 남는다.
실패한 실행의 디렉터리를 덮어쓰거나 저장 plan을 무조건 재적용하지 않는다. SSM 명령이 아직 실행 중인지,
State와 AWS 리소스 상태를 확인하고 원인을 해결한 뒤 새 디렉터리에서 다시 계획한다.
클러스터/Bastion이 이미 없거나 Controller/CRD가 준비되지 않은 부분 배포 상태는 자동 우회하지 않으며,
그 상태의 리소스 정리는 별도 검토가 필요하다. 실행 중에는 다른 배포/수동 변경을 중지한다.

참고: [Terraform 저장 destroy plan](https://developer.hashicorp.com/terraform/cli/commands/plan),
[ALB 삭제 보호 annotation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/).

## 로컬 검증

```bash
python3 -m pip install PyYAML==6.0.2
python3 -m unittest discover -s scripts/eks/tests -v
python3 -m unittest discover -s monitoring/tests -v
./scripts/validate.sh
./monitoring/validate-configs.sh
terraform -chdir=infra/environments/dev-eks validate
terraform -chdir=infra/environments/dev-eks test
```
