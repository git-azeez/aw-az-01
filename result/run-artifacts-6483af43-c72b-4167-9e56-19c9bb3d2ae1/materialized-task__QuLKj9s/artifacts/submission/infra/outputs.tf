output "manifest" {
  sensitive = true
  value = {
    resource_prefix = local.prefix
    region          = local.region
    service_url     = "http://${regex("^https?://([^/:]+)", local.endpoint)[0]}:80"
    network = {
      vpc_id             = aws_vpc.main.id
      public_subnet_ids  = local.public_ids
      private_subnet_ids = local.private_ids
      security_group_ids = { alb = aws_security_group.alb.id, ecs = aws_security_group.ecs.id, rds = aws_security_group.rds.id, valkey = aws_security_group.valkey.id }
    }
    ingress     = { alb_arn = aws_lb.api.arn, alb_dns_name = aws_lb.api.dns_name, listener_arn = aws_lb_listener.api.arn, target_group_arn = aws_lb_target_group.api.arn, container_port = 8080 }
    compute     = { cluster_arn = aws_ecs_cluster.api.arn, cluster_name = aws_ecs_cluster.api.name, service_arn = aws_ecs_service.api.id, service_name = aws_ecs_service.api.name, task_definition_arn = aws_ecs_task_definition.api.arn, desired_count = 2 }
    database    = { instance_id = aws_db_instance.database.identifier, instance_arn = aws_db_instance.database.arn, endpoint = aws_db_instance.database.address, port = aws_db_instance.database.port, db_name = local.c.db_name, username = local.c.db_username }
    messaging   = { queue_name = aws_sqs_queue.main.name, queue_url = aws_sqs_queue.main.url, queue_arn = aws_sqs_queue.main.arn, dlq_name = aws_sqs_queue.dlq.name, dlq_url = aws_sqs_queue.dlq.url, dlq_arn = aws_sqs_queue.dlq.arn, event_source_mapping_uuid = aws_lambda_event_source_mapping.projector.uuid, max_receive_count = 4 }
    workers     = { projector = { function_name = aws_lambda_function.worker["projector"].function_name, function_arn = aws_lambda_function.worker["projector"].arn }, outbox_relay = { function_name = aws_lambda_function.worker["relay"].function_name, function_arn = aws_lambda_function.worker["relay"].arn }, audit_archiver = { function_name = aws_lambda_function.worker["archiver"].function_name, function_arn = aws_lambda_function.worker["archiver"].arn } }
    projections = { table_name = aws_dynamodb_table.projection.name, table_arn = aws_dynamodb_table.projection.arn, gsi_name = "AccountIndex" }
    cache       = { cluster_id = aws_elasticache_replication_group.cache.id, engine = aws_elasticache_replication_group.cache.engine, endpoint = local.cache_endpoint, port = 6379 }
    audit       = { bucket_name = aws_s3_bucket.audit.id, bucket_arn = aws_s3_bucket.audit.arn, prefix = "ledger-audit/" }
    schedules   = { outbox_schedule_name = aws_scheduler_schedule.worker["relay"].name, outbox_schedule_arn = aws_scheduler_schedule.worker["relay"].arn, archive_schedule_name = aws_scheduler_schedule.worker["archiver"].name, archive_schedule_arn = aws_scheduler_schedule.worker["archiver"].arn }
    auth        = { user_pool_id = aws_cognito_user_pool.auth.id, user_pool_arn = aws_cognito_user_pool.auth.arn, issuer_url = local.issuer, token_endpoint = "${local.endpoint}/cognito-idp/oauth2/token", resource_server_identifier = "clearledger", clients = { for k, v in aws_cognito_user_pool_client.auth : k => { client_id = v.id, client_secret = v.client_secret, scope = "clearledger/${k}" } } }
    iam         = { ecs_execution_role_arn = aws_iam_role.workload["ecs_execution"].arn, ecs_task_role_arn = aws_iam_role.workload["ecs_task"].arn, projector_role_arn = aws_iam_role.workload["projector"].arn, relay_role_arn = aws_iam_role.workload["relay"].arn, archiver_role_arn = aws_iam_role.workload["archiver"].arn, scheduler_role_arn = aws_iam_role.workload["scheduler"].arn }
    kms         = { database_arn = aws_kms_key.store["database"].arn, messaging_arn = aws_kms_key.store["messaging"].arn, projection_arn = aws_kms_key.store["projection"].arn, audit_arn = aws_kms_key.store["audit"].arn }
    logs        = { api_log_group = aws_cloudwatch_log_group.workload["api"].name, projector_log_group = aws_cloudwatch_log_group.workload["projector"].name, relay_log_group = aws_cloudwatch_log_group.workload["relay"].name, archiver_log_group = aws_cloudwatch_log_group.workload["archiver"].name }
  }
}
