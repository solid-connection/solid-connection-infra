#!/usr/bin/env bash
# Read the type selected by Start from the DB resource in state.
load_test_db_instance_type_from_state() {
  local state_json value
  if ! state_json="$(terraform -chdir="$TERRAFORM_DIR" show -json)"; then
    echo "Cannot read Terraform state for the load-test DB instance type" >&2
    return 1
  fi
  if ! value="$(jq -r '
    first(.values.root_module.resources[]?
      | select(.address == "aws_instance.load_test_db")
      | .values.instance_type) // empty
  ' <<< "$state_json")"; then
    echo "Cannot parse Terraform state for the load-test DB instance type" >&2
    return 1
  fi
  if [[ -z "$value" ]]; then
    echo "Cannot read the load-test DB instance type from Terraform state; run Start first" >&2
    return 1
  fi
  printf '%s\n' "$value"
}
