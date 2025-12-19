# solid-connection-infra
solid-connection 서비스의 AWS, terraform 기반 IaC 레포지토리입니다.


## 디렉토리 구조
```
solid-connection-infra/
├── modules/
│   └── app_stack/            # [공통 모듈] API Server + RDS 정의
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    ├── prod/                 # [Prod 환경]
    │   ├── main.tf
    │   ├── provider.tf
    │   ├── variables.tf
    │   └── secret.tfvars     
    ├── stage/                # [Stage 환경]
    │   ├── main.tf
    │   ├── provider.tf
    │   ├── variables.tf
    │   └── secret.tfvars
    ├── load_test/            # [부하테스트 환경]
    │   ├── main.tf
    │   ├── provider.tf
    │   ├── variables.tf
    │   └── secret.tfvars
    └── monitoring/           # [Monitoring 환경] (Grafana 단독)
        ├── main.tf
        ├── provider.tf
        ├── variables.tf
        └── secret.tfvars
```