# travel-gitops

KDT Travel Diary MSA의 Kubernetes 배포 선언을 관리하는 GitOps 레포입니다.

- 대상 환경: Kind 개발 클러스터
- CD 도구: Argo CD
- 배포 서비스: identity-service, community-service, travel-service, maps-service
- travel-common은 공통 라이브러리이므로 배포 대상이 아닙니다.
- 서비스 이미지, Dockerfile, Deployment/Service/Ingress 사양 확정 전까지 실제 서비스 배포 및 자동 sync는 구성하지 않습니다.
