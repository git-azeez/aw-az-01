# Lambda Workers and Event Source Mapping (`services/lambda.md`)

Provision three container-based AWS Lambda functions (`aws_lambda_function`, `package_type = "Image"`):

1. **Projector (`workers.projector`)**:
   - `image_uri = projector_image` from `config.json`
   - `role = iam.projector_role_arn`
   - Environment variables: `AWS_ENDPOINT_URL`, `PROJECTION_TABLE`, `VALKEY_URL`, `CLOUDWATCH_LOG_GROUP`
   - Wired to the main SQS queue via an `aws_lambda_event_source_mapping` with:
     - `enabled = true`
     - `batch_size = 5`
     - `maximum_batching_window_in_seconds = 0`
     - `function_response_types = ["ReportBatchItemFailures"]`
2. **Outbox Relay (`workers.outbox_relay`)**:
   - `image_uri = relay_image` from `config.json`
   - `role = iam.relay_role_arn`
   - Environment variables: `AWS_ENDPOINT_URL`, `DATABASE_URL`, `SQS_QUEUE_URL`, `OUTBOX_BATCH_SIZE = "50"`, `CLOUDWATCH_LOG_GROUP`
3. **Audit Archiver (`workers.audit_archiver`)**:
   - `image_uri = archiver_image` from `config.json`
   - `role = iam.archiver_role_arn`
   - Environment variables: `AWS_ENDPOINT_URL`, `DATABASE_URL`, `AUDIT_BUCKET`, `AUDIT_PREFIX = "ledger-audit/"`, `CLOUDWATCH_LOG_GROUP`
