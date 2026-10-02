# CloudWatch Log Groups (`services/cloudwatch-logs.md`)

Provision four dedicated CloudWatch Log Groups (`aws_cloudwatch_log_group`), each with `retention_in_days = 14` (at least `14` days):

- `logs.api_log_group`: `/clearledger/<resource_prefix>/api`
- `logs.projector_log_group`: `/clearledger/<resource_prefix>/projector`
- `logs.relay_log_group`: `/clearledger/<resource_prefix>/outbox-relay`
- `logs.archiver_log_group`: `/clearledger/<resource_prefix>/audit-archiver`
