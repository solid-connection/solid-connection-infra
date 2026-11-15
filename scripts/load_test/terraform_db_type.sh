#!/usr/bin/env bash
# Read the type selected by Start from state, including states created before the output existed.
load_test_db_instance_type_from_state() {
  local value
  value="$(terraform -chdir="$TERRAFORM_DIR" output -raw load_test_db_instance_type 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$(terraform -chdir="$TERRAFORM_DIR" show -json | jq -r '
      .values.root_module.resources[]?
      | select(.address == "aws_instance.load_test_db")
      | .values.instance_type
    ')"
  fi
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "Cannot read the load-test DB instance type from Terraform state; run Start first" >&2
    return 1
  fi
  printf '%s\n' "$value"
}
