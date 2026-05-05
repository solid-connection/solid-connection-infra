# Load Test Automation

This automation creates a temporary load test RDS instance, copies prod RDS data
into it, writes load test datasource values to Parameter Store, and switches the
stage application through SSM Run Command.

## GitHub Actions Flow

### Start

1. Open **Actions > Load Test Start**.
2. Click **Run workflow**.
3. Keep `switch_stage_to_loadtest` enabled to restart stage with
   `dev,loadtest` profiles.
4. Keep `copy_prod_data` enabled to copy prod RDS data into the load test RDS.

The workflow runs `scripts/load_test/start.sh`.

### Stop

1. Open **Actions > Load Test Stop**.
2. Click **Run workflow**.
3. Keep `restore_stage_dev` enabled to restart stage with the normal dev
   compose configuration.
4. Keep `destroy_rds` enabled to destroy the load test Terraform stack.

The workflow runs `scripts/load_test/stop.sh`.

## What Start Does

1. Runs `terraform apply` in `environment/load_test`.
2. Creates the load test RDS and writes:
   - `/solid-connection/loadtest/spring.datasource.url`
   - `/solid-connection/loadtest/spring.datasource.username`
   - `/solid-connection/loadtest/spring.datasource.password`
3. Switches the stage app to `dev,loadtest` profiles through SSM Run Command.
4. Stores DB migration credentials in temporary SSM parameters.
5. Runs `mysqldump` on the prod EC2 instance through SSM Run Command and
   restores the dump into the load test RDS.
6. Deletes the temporary migration parameters.

## What Stop Does

1. Restores the stage app to the normal dev compose configuration through SSM
   Run Command.
2. Runs `terraform destroy` for the load test Terraform stack.

## Notes

- GitHub Actions uses `AWS_ROLE_ARN` through OIDC.
- Private submodule checkout uses `GH_PAT`.
- No SSH private key is required for load test start/stop.
- The prod and stage EC2 instances are looked up by their `Name` tags.
- Prod DB username/password are read from Parameter Store. The default paths are
  `/solid-connection/prod/spring.datasource.username` and
  `/solid-connection/prod/spring.datasource.password`.
- Load test DB username/password are read from Parameter Store. The default paths
  are `/solid-connection/loadtest/spring.datasource.username` and
  `/solid-connection/loadtest/spring.datasource.password`.
- The load test RDS security group allows MySQL only from the security groups
  attached to the prod and stage API EC2 instances.
