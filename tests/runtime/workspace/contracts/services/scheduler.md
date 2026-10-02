# EventBridge Scheduler (`services/scheduler.md`)

Provision two enabled EventBridge Scheduler schedules (`aws_scheduler_schedule`, `state = "ENABLED"`, `flexible_time_window { mode = "OFF" }`):

1. **Outbox Relay Schedule (`schedules.outbox_schedule_name`)**:
   - `schedule_expression = "rate(1 minute)"`
   - `target.arn = workers.outbox_relay.function_arn`
   - `target.role_arn = iam.scheduler_role_arn`
2. **Audit Archiver Schedule (`schedules.archive_schedule_name`)**:
   - `schedule_expression = "rate(5 minutes)"`
   - `target.arn = workers.audit_archiver.function_arn`
   - `target.role_arn = iam.scheduler_role_arn`
