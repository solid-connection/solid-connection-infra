# Load Test Automation

This automation creates a temporary load test RDS instance, copies prod RDS data
into it, writes load test datasource values to Parameter Store, and optionally
stops/starts the stage application through SSM Run Command.

## Flow

1. `Start-LoadTest.ps1` runs `terraform apply` in `environment/load_test`.
2. Terraform creates the load test RDS and writes:
   - `/solid-connection/loadtest/spring.datasource.url`
   - `/solid-connection/loadtest/spring.datasource.username`
   - `/solid-connection/loadtest/spring.datasource.password`
3. The script stores DB migration credentials in temporary SSM parameters.
4. The prod EC2 instance runs `mysqldump` against prod RDS and restores it into
   the load test RDS.
5. The optional stage stop command can pause the stage app before the load test.
6. `Stop-LoadTest.ps1` can run an optional stage start command and then destroy
   only the load test Terraform stack.

## Example

```bash
scripts/load_test/start.sh \
  --switch-stage-to-loadtest \
  --stage-ssh-key ./stage-key.pem
```

```bash
scripts/load_test/stop.sh \
  --restore-stage-dev \
  --stage-ssh-key ./stage-key.pem
```

## Notes

- The prod and stage EC2 instances are looked up by their `Name` tags.
- Prod DB username/password are read from Parameter Store. The default paths are
  `/solid-connection/prod/spring.datasource.username` and
  `/solid-connection/prod/spring.datasource.password`.
- Load test DB username/password are also read from Parameter Store. The default
  paths are `/solid-connection/loadtest/spring.datasource.username` and
  `/solid-connection/loadtest/spring.datasource.password`.
- The load test RDS security group allows MySQL only from the security groups
  attached to the prod and stage API EC2 instances.
- The prod EC2 instance must have SSM access and permission to read the temporary
  migration parameters.
- Keep the real `load_test.tfvars` in the secret submodule or another ignored
  local location. Do not commit it.
