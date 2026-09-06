# 부분 설정. 실제 값은 init 시 -backend-config 로 주입한다:
#   terraform init \
#     -backend-config="bucket=<tfstate-bucket>" \
#     -backend-config="key=msa/dev/terraform.tfstate" \
#     -backend-config="region=ap-northeast-2"
# 모놀리스와 같은 tfstate 버킷을 재사용하되 key 는 msa/ 로 분리한다.
terraform {
  backend "s3" {}
}
