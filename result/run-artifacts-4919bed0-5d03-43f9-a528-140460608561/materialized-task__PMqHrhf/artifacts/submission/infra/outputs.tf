output "manifest" {
  sensitive = true
  value = {
    resource_prefix = local.p
    region          = local.region
    service_url     = "http://${split(":", split("://", local.endpoint)[1])[0]}:80"
    network = {
      vpc_id             = aws_vpc.main.id
      public_subnet_ids  = aws_subnet.public[*].id
      private_subnet_ids = aws_subnet.private[*].id
      security_group_ids = { alb = aws_security_group.alb.id, ecs = aws_security_group.ecs.id, rds = aws_security_group.rds.id, valkey = aws_security_group.valkey.id }
    }
    ingress     = { alb_arn = aws_lb.api.arn, alb_dns_name = aws_lb.api.dns_name, listener_arn = aws_lb_listener.api.arn, target_group_arn = aws_lb_target_group.api.arn, container_port = 8080 }
    compute     = { cluster_arn = aws_ecs_cluster.api.arn, cluster_name = aws_ecs_cluster.api.name, service_arn = aws_ecs_service.api.id, service_name = aws_ecs_service.api.name, task_definition_arn = aws_ecs_task_definition.api.arn, desired_count = 2 }
    database    = { instance_id = aws_db_instance.db.identifier, instance_arn = aws_db_instance.db.arn, endpoint = aws_db_instance.db.address, port = aws_db_instance.db.port, db_name = local.c.db_name, username = local.c.db_username }
    messaging   = { queue_name = aws_sqs_queue.events.name, queue_url = aws_sqs_queue.events.url, queue_arn = aws_sqs_queue.events.arn, dlq_name = aws_sqs_queue.dlq.name, dlq_url = aws_sqs_queue.dlq.url, dlq_arn = aws_sqs_queue.dlq.arn, event_source_mapping_uuid = aws_lambda_event_source_mapping.projector.uuid, max_receive_count = 4 }
    workers     = { for k, v in { projector = "projector", outbox_relay = "relay", audit_archiver = "archiver" } : k => { function_name = aws_lambda_function.workers[v].function_name, function_arn = aws_lambda_function.workers[v].arn } }
    projections = { table_name = aws_dynamodb_table.projection.name, table_arn = aws_dynamodb_table.projection.arn, gsi_name = "AccountIndex" }
    cache       = { cluster_id = aws_elasticache_replication_group.cache.id, engine = "valkey", endpoint = local.valkey_host, port = 6379 }
    audit       = { bucket_name = aws_s3_bucket.audit.id, bucket_arn = aws_s3_bucket.audit.arn, prefix = "ledger-audit/" }
    schedules   = { outbox_schedule_name = aws_scheduler_schedule.workers["relay"].name, outbox_schedule_arn = aws_scheduler_schedule.workers["relay"].arn, archive_schedule_name = aws_scheduler_schedule.workers["archiver"].name, archive_schedule_arn = aws_scheduler_schedule.workers["archiver"].arn }
    auth = {
      user_pool_id               = aws_cognito_user_pool.auth.id, user_pool_arn = aws_cognito_user_pool.auth.arn,
      issuer_url                 = "${local.endpoint}/${aws_cognito_user_pool.auth.id}", token_endpoint = "${local.endpoint}/cognito-idp/oauth2/token",
      resource_server_identifier = "clearledger",
      clients                    = { for k, v in aws_cognito_user_pool_client.clients : k => { client_id = v.id, client_secret = v.client_secret, scope = "clearledger/${k}" } }
    }
    iam  = { for k, v in aws_iam_role.roles : "${k}_role_arn" => v.arn }
    kms  = { for k, v in aws_kms_key.keys : "${k}_arn" => v.arn }
    logs = { for k, v in aws_cloudwatch_log_group.logs : "${k}_log_group" => v.name }
  }
}
