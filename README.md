# travel-gitops

KDT Travel Diary MSA의 Kubernetes 배포 선언을 관리하는 GitOps 레포입니다.

## 범위

- 대상 환경: Kind 개발 클러스터
- CD 도구: Argo CD
- 배포 대상: `identity-service`, `community-service`, `travel-service`, `maps-service`
- `travel-common`은 공통 라이브러리이므로 Kubernetes 배포 대상이 아닙니다.

## 현재 단계

서비스 Dockerfile, 이미지 태그, 포트와 Deployment/Service/Ingress 사양이 확정되기 전입니다.
따라서 현재는 디렉터리 구조와 플랫폼 설계만 준비하며, 서비스 Application sync 또는 자동 배포는 구성하지 않습니다.

## 디렉터리

- `bootstrap/`: 추후 클러스터에 한 번 적용할 Argo CD 루트 Application
- `clusters/kind-dev/platform/`: Kind 개발 클러스터의 네임스페이스, ingress-nginx, Argo CD 프로젝트 선언
- `apps/<service>/`: 서비스별 Kubernetes 매니페스트와 환경 오버레이
