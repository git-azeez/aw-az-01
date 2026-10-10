output "manifest" {
  sensitive = true
  value = {
    resource_prefix = local.prefix
    region          = var.region
    service_url     = replace(var.aws_endpoint_url, "/:[0-9]+$/", ":80")
    network = {
      vpc_id             = aws_vpc.network.id
      public_subnet_ids  = aws_subnet.public[*].id
      private_subnet_ids = aws_subnet.private[*].id
      security_group_ids = { alb = aws_security_group.alb.id, ecs = aws_security_group.ecs.id, rds = aws_security_group.rds.id, valkey = aws_security_group.valkey.id }
    }
    ingress     = { alb_arn = aws_lb.api.arn, alb_dns_name = aws_lb.api.dns_name, listener_arn = aws_lb_listener.api.arn, target_group_arn = aws_lb_target_group.api.arn, container_port = 8080 }
    compute     = { cluster_arn = aws_ecs_cluster.api.arn, cluster_name = aws_ecs_cluster.api.name, service_arn = aws_ecs_service.api.id, service_name = aws_ecs_service.api.name, task_definition_arn = aws_ecs_task_definition.api.arn, desired_count = 2 }
    database    = { instance_id = aws_db_instance.database.identifier, instance_arn = aws_db_instance.database.arn, endpoint = aws_db_instance.database.address, port = aws_db_instance.database.port, db_name = var.db_name, username = var.db_username }
    messaging   = { queue_name = aws_sqs_queue.events.name, queue_url = aws_sqs_queue.events.url, queue_arn = aws_sqs_queue.events.arn, dlq_name = aws_sqs_queue.dlq.name, dlq_url = aws_sqs_queue.dlq.url, dlq_arn = aws_sqs_queue.dlq.arn, event_source_mapping_uuid = aws_lambda_event_source_mapping.projector.uuid, max_receive_count = 4 }
    workers     = { projector = { function_name = aws_lambda_function.workers["projector"].function_name, function_arn = aws_lambda_function.workers["projector"].arn }, outbox_relay = { function_name = aws_lambda_function.workers["relay"].function_name, function_arn = aws_lambda_function.workers["relay"].arn }, audit_archiver = { function_name = aws_lambda_function.workers["archiver"].function_name, function_arn = aws_lambda_function.workers["archiver"].arn } }
    projections = { table_name = aws_dynamodb_table.projection.name, table_arn = aws_dynamodb_table.projection.arn, gsi_name = "AccountIndex" }
    cache       = { cluster_id = aws_elasticache_replication_group.cache.id, engine = "valkey", endpoint = local.cache_endpoint, port = 6379 }
    audit       = { bucket_name = aws_s3_bucket.audit.id, bucket_arn = aws_s3_bucket.audit.arn, prefix = "ledger-audit/" }
    schedules   = { outbox_schedule_name = aws_scheduler_schedule.workers["relay"].name, outbox_schedule_arn = aws_scheduler_schedule.workers["relay"].arn, archive_schedule_name = aws_scheduler_schedule.workers["archiver"].name, archive_schedule_arn = aws_scheduler_schedule.workers["archiver"].arn }
    auth = {
      user_pool_id   = aws_cognito_user_pool.auth.id, user_pool_arn = aws_cognito_user_pool.auth.arn, issuer_url = local.issuer,
      token_endpoint = "${var.aws_endpoint_url}/cognito-idp/oauth2/token", resource_server_identifier = "clearledger",
      clients        = { for k, v in aws_cognito_user_pool_client.clients : k => { client_id = v.id, client_secret = v.client_secret, scope = "clearledger/${k}" } }
    }
    iam  = { for k, v in aws_iam_role.roles : "${k}_role_arn" => v.arn }
    kms  = { for k, v in aws_kms_key.keys : "${k}_arn" => v.arn }
    logs = { api_log_group = aws_cloudwatch_log_group.logs["api"].name, projector_log_group = aws_cloudwatch_log_group.logs["projector"].name, relay_log_group = aws_cloudwatch_log_group.logs["relay"].name, archiver_log_group = aws_cloudwatch_log_group.logs["archiver"].name }
  }
}
