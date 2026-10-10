output "manifest" {
  sensitive = true
  value = {
    resource_prefix = local.p
    region          = local.region
    service_url     = "http://${split(":", split("//", local.endpoint)[1])[0]}:80"
    network = {
      vpc_id             = aws_vpc.main.id
      public_subnet_ids  = aws_subnet.public[*].id
      private_subnet_ids = aws_subnet.private[*].id
      security_group_ids = { alb = aws_security_group.alb.id, ecs = aws_security_group.ecs.id, rds = aws_security_group.store["rds"].id, valkey = aws_security_group.store["valkey"].id }
    }
    ingress     = { alb_arn = aws_lb.main.arn, alb_dns_name = aws_lb.main.dns_name, listener_arn = aws_lb_listener.main.arn, target_group_arn = aws_lb_target_group.main.arn, container_port = 8080 }
    compute     = { cluster_arn = aws_ecs_cluster.main.arn, cluster_name = aws_ecs_cluster.main.name, service_arn = aws_ecs_service.api.id, service_name = aws_ecs_service.api.name, task_definition_arn = aws_ecs_task_definition.api.arn, desired_count = 2 }
    database    = { instance_id = aws_db_instance.main.identifier, instance_arn = aws_db_instance.main.arn, endpoint = aws_db_instance.main.address, port = aws_db_instance.main.port, db_name = local.c.db_name, username = local.c.db_username }
    messaging   = { queue_name = aws_sqs_queue.main.name, queue_url = aws_sqs_queue.main.url, queue_arn = aws_sqs_queue.main.arn, dlq_name = aws_sqs_queue.dlq.name, dlq_url = aws_sqs_queue.dlq.url, dlq_arn = aws_sqs_queue.dlq.arn, event_source_mapping_uuid = aws_lambda_event_source_mapping.projector.uuid, max_receive_count = 4 }
    workers     = { for name, role in { projector = "projector", outbox_relay = "relay", audit_archiver = "archiver" } : name => { function_name = aws_lambda_function.worker[role].function_name, function_arn = aws_lambda_function.worker[role].arn } }
    projections = { table_name = aws_dynamodb_table.main.name, table_arn = aws_dynamodb_table.main.arn, gsi_name = "AccountIndex" }
    cache       = { cluster_id = aws_elasticache_replication_group.main.id, engine = "valkey", endpoint = local.cache_host, port = 6379 }
    audit       = { bucket_name = aws_s3_bucket.audit.id, bucket_arn = aws_s3_bucket.audit.arn, prefix = "ledger-audit/" }
    schedules   = { outbox_schedule_name = aws_scheduler_schedule.worker["relay"].name, outbox_schedule_arn = aws_scheduler_schedule.worker["relay"].arn, archive_schedule_name = aws_scheduler_schedule.worker["archiver"].name, archive_schedule_arn = aws_scheduler_schedule.worker["archiver"].arn }
    auth = {
      user_pool_id = aws_cognito_user_pool.main.id, user_pool_arn = aws_cognito_user_pool.main.arn,
      issuer_url   = "${local.endpoint}/${aws_cognito_user_pool.main.id}", token_endpoint = "${local.endpoint}/cognito-idp/oauth2/token", resource_server_identifier = "clearledger",
      clients      = { for r, c in aws_cognito_user_pool_client.client : r => { client_id = c.id, client_secret = c.client_secret, scope = "clearledger/${r}" } }
    }
    iam  = { for r, role in aws_iam_role.role : "${r}_role_arn" => role.arn }
    kms  = { for k, key in aws_kms_key.key : "${k}_arn" => key.arn }
    logs = { for r, g in aws_cloudwatch_log_group.log : "${r}_log_group" => g.name }
  }
}
