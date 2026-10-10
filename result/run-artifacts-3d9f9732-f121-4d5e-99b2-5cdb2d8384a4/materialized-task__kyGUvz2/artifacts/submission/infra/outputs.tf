locals {
  service_url = "http://aws:80"
}

output "manifest" {
  sensitive = true
  value = {
    resource_prefix = local.prefix
    region          = var.region
    service_url     = local.service_url

    network = {
      vpc_id             = aws_vpc.main.id
      public_subnet_ids  = aws_subnet.public[*].id
      private_subnet_ids = aws_subnet.private[*].id
      security_group_ids = {
        alb    = aws_security_group.alb.id
        ecs    = aws_security_group.ecs.id
        rds    = aws_security_group.rds.id
        valkey = aws_security_group.valkey.id
      }
    }

    ingress = {
      alb_arn          = aws_lb.main.arn
      alb_dns_name     = aws_lb.main.dns_name
      listener_arn     = aws_lb_listener.http.arn
      target_group_arn = aws_lb_target_group.api.arn
      container_port   = 8080
    }

    compute = {
      cluster_arn         = aws_ecs_cluster.main.arn
      cluster_name        = aws_ecs_cluster.main.name
      service_arn         = aws_ecs_service.api.id
      service_name        = aws_ecs_service.api.name
      task_definition_arn = aws_ecs_task_definition.api.arn
      desired_count       = aws_ecs_service.api.desired_count
    }

    database = {
      instance_id  = aws_db_instance.main.identifier
      instance_arn = aws_db_instance.main.arn
      endpoint     = aws_db_instance.main.address
      port         = aws_db_instance.main.port
      db_name      = var.db_name
      username     = var.db_username
    }

    messaging = {
      queue_name                = aws_sqs_queue.main.name
      queue_url                 = aws_sqs_queue.main.url
      queue_arn                 = aws_sqs_queue.main.arn
      dlq_name                  = aws_sqs_queue.dlq.name
      dlq_url                   = aws_sqs_queue.dlq.url
      dlq_arn                   = aws_sqs_queue.dlq.arn
      event_source_mapping_uuid = aws_lambda_event_source_mapping.projector.uuid
      max_receive_count         = 4
    }

    workers = {
      projector      = { function_name = aws_lambda_function.projector.function_name, function_arn = aws_lambda_function.projector.arn }
      outbox_relay   = { function_name = aws_lambda_function.outbox_relay.function_name, function_arn = aws_lambda_function.outbox_relay.arn }
      audit_archiver = { function_name = aws_lambda_function.audit_archiver.function_name, function_arn = aws_lambda_function.audit_archiver.arn }
    }

    projections = {
      table_name = aws_dynamodb_table.projection.name
      table_arn  = aws_dynamodb_table.projection.arn
      gsi_name   = "AccountIndex"
    }

    cache = {
      cluster_id = aws_elasticache_replication_group.main.replication_group_id
      engine     = "valkey"
      endpoint   = local.valkey_host
      port       = 6379
    }

    audit = {
      bucket_name = aws_s3_bucket.audit.bucket
      bucket_arn  = aws_s3_bucket.audit.arn
      prefix      = local.audit_prefix
    }

    schedules = {
      outbox_schedule_name  = aws_scheduler_schedule.outbox.name
      outbox_schedule_arn   = aws_scheduler_schedule.outbox.arn
      archive_schedule_name = aws_scheduler_schedule.archive.name
      archive_schedule_arn  = aws_scheduler_schedule.archive.arn
    }

    auth = {
      user_pool_id               = aws_cognito_user_pool.main.id
      user_pool_arn              = aws_cognito_user_pool.main.arn
      issuer_url                 = "http://aws:4566/${aws_cognito_user_pool.main.id}"
      token_endpoint             = "http://aws:4566/cognito-idp/oauth2/token"
      resource_server_identifier = aws_cognito_resource_server.main.identifier
      clients = {
        for k, c in aws_cognito_user_pool_client.this : k => {
          client_id     = c.id
          client_secret = c.client_secret
          scope         = "clearledger/${k}"
        }
      }
    }

    iam = {
      ecs_execution_role_arn = aws_iam_role.this["ecs_execution"].arn
      ecs_task_role_arn      = aws_iam_role.this["ecs_task"].arn
      projector_role_arn     = aws_iam_role.this["projector"].arn
      relay_role_arn         = aws_iam_role.this["relay"].arn
      archiver_role_arn      = aws_iam_role.this["archiver"].arn
      scheduler_role_arn     = aws_iam_role.this["scheduler"].arn
    }

    kms = {
      database_arn   = aws_kms_key.this["database"].arn
      messaging_arn  = aws_kms_key.this["messaging"].arn
      projection_arn = aws_kms_key.this["projection"].arn
      audit_arn      = aws_kms_key.this["audit"].arn
    }

    logs = {
      api_log_group       = aws_cloudwatch_log_group.this["api"].name
      projector_log_group = aws_cloudwatch_log_group.this["projector"].name
      relay_log_group     = aws_cloudwatch_log_group.this["relay"].name
      archiver_log_group  = aws_cloudwatch_log_group.this["archiver"].name
    }
  }
}
