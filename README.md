# solid-connection-infra
solid-connection 서비스의 AWS, terraform 기반 IaC 레포지토리입니다.


## 디렉토리 구조
```
solid-connection-infra/
├── config/
│   ├── secrets/              # 민감한 data 관리
│   │   └── ...
│   └── side-infra/           # [side infra 관련 설정]
│       └── config.alloy
├── modules/
│   └── app_stack/            # [Prod/Stage 환경의 공통 모듈]
│       ├── scripts
│       │   └── docker_setup.sh
│       │   └── nginx_setup.sh.tftpl
│       │   └── side_infra_setup.sh.tftpl
│       ├── security_groups.tf
│       ├── ec2.tf
│       ├── rds.tf
│       ├── s3.tf
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    ├── prod/                 # [Prod 환경]
    │   ├── main.tf
    │   ├── provider.tf
    │   └── variables.tf    
    ├── stage/                # [Stage 환경]
    │   ├── main.tf
    │   ├── provider.tf
    │   └── variables.tf
    ├── load_test/            # [부하테스트 환경]
    │   ├── main.tf
    │   ├── provider.tf
    │   └── variables.tf
    └── monitoring/           # [Monitoring 환경]
        ├── main.tf
        ├── provider.tf
        └── variables.tf
```
