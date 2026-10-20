config {
  # environment/* 가 호출하는 로컬 모듈(modules/*)까지 함께 검사한다.
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# ---------------------------------------------------------------------------
# 기존 코드 baseline (#89 도입 시점)
#
# 아래 규칙은 기존 코드에 위반이 남아 있어 일시적으로 끈다.
# 정리하려면 provider/버전 제약 추가, 변수 type 지정, 미사용 변수 제거(secrets tfvars 와 함께 정리)가 필요하며
# plan 결과에 영향을 줄 수 있어 검증 파이프라인 도입과 분리해 진행한다. 정리 후 이 블록을 제거한다.
# ---------------------------------------------------------------------------
rule "terraform_required_providers" {
  enabled = false
}

rule "terraform_required_version" {
  enabled = false
}

rule "terraform_typed_variables" {
  enabled = false
}

rule "terraform_unused_declarations" {
  enabled = false
}
