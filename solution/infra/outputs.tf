output "manifest" {
  sensitive = true
  value = {
    resource_prefix = local.prefix
    region          = var.region
    service_url     = "http://${local.aws_endpoint_host}:80"
    network = {
      vpc_id             = aws_vpc.main.id
      public_subnet_ids  = [aws_subnet.public_a.id, aws_subnet.public_b.id]
      private_subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
      security_group_ids = {
        alb    = aws_security_group.alb.id
        ecs    = aws_security_group.ecs.id
        rds    = aws_security_group.rds.id
        valkey = aws_security_group.valkey.id
      }
    }
    ingress = {
      alb_arn          = aws_lb.api.arn
      alb_dns_name     = aws_lb.api.dns_name
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
      endpoint     = local.database_host
      port         = local.database_port
      db_name      = aws_db_instance.main.db_name
      username     = aws_db_instance.main.username
    }
    messaging = {
      queue_name                = aws_sqs_queue.events.name
      queue_url                 = aws_sqs_queue.events.url
      queue_arn                 = aws_sqs_queue.events.arn
      dlq_name                  = aws_sqs_queue.dlq.name
      dlq_url                   = aws_sqs_queue.dlq.url
      dlq_arn                   = aws_sqs_queue.dlq.arn
      event_source_mapping_uuid = aws_lambda_event_source_mapping.projector_sqs.uuid
      max_receive_count         = 4
    }
    workers = {
      projector = {
        function_name = aws_lambda_function.projector.function_name
        function_arn  = aws_lambda_function.projector.arn
      }
      outbox_relay = {
        function_name = aws_lambda_function.outbox_relay.function_name
        function_arn  = aws_lambda_function.outbox_relay.arn
      }
      audit_archiver = {
        function_name = aws_lambda_function.audit_archiver.function_name
        function_arn  = aws_lambda_function.audit_archiver.arn
      }
    }
    projections = {
      table_name = aws_dynamodb_table.projections.name
      table_arn  = aws_dynamodb_table.projections.arn
      gsi_name   = "AccountIndex"
    }
    cache = {
      cluster_id = aws_elasticache_replication_group.valkey.id
      engine     = "valkey"
      endpoint   = local.valkey_host
      port       = local.valkey_port
    }
    audit = {
      bucket_name = aws_s3_bucket.audit.bucket
      bucket_arn  = aws_s3_bucket.audit.arn
      prefix      = "ledger-audit/"
    }
    schedules = {
      outbox_schedule_name  = aws_scheduler_schedule.outbox_relay.name
      outbox_schedule_arn   = aws_scheduler_schedule.outbox_relay.arn
      archive_schedule_name = aws_scheduler_schedule.audit_archiver.name
      archive_schedule_arn  = aws_scheduler_schedule.audit_archiver.arn
    }
    auth = {
      user_pool_id               = aws_cognito_user_pool.main.id
      user_pool_arn              = aws_cognito_user_pool.main.arn
      issuer_url                 = local.cognito_issuer
      token_endpoint             = local.cognito_token
      resource_server_identifier = aws_cognito_resource_server.clearledger.identifier
      clients = {
        read = {
          client_id     = aws_cognito_user_pool_client.read.id
          client_secret = aws_cognito_user_pool_client.read.client_secret
          scope         = "clearledger/read"
        }
        write = {
          client_id     = aws_cognito_user_pool_client.write.id
          client_secret = aws_cognito_user_pool_client.write.client_secret
          scope         = "clearledger/write"
        }
        admin = {
          client_id     = aws_cognito_user_pool_client.admin.id
          client_secret = aws_cognito_user_pool_client.admin.client_secret
          scope         = "clearledger/admin"
        }
      }
    }
    iam = {
      ecs_execution_role_arn = aws_iam_role.ecs_execution.arn
      ecs_task_role_arn      = aws_iam_role.ecs_task.arn
      projector_role_arn     = aws_iam_role.projector.arn
      relay_role_arn         = aws_iam_role.relay.arn
      archiver_role_arn      = aws_iam_role.archiver.arn
      scheduler_role_arn     = aws_iam_role.scheduler.arn
    }
    kms = {
      database_arn   = aws_kms_key.database.arn
      messaging_arn  = aws_kms_key.messaging.arn
      projection_arn = aws_kms_key.projection.arn
      audit_arn      = aws_kms_key.audit.arn
    }
    logs = {
      api_log_group       = aws_cloudwatch_log_group.api.name
      projector_log_group = aws_cloudwatch_log_group.projector.name
      relay_log_group     = aws_cloudwatch_log_group.relay.name
      archiver_log_group  = aws_cloudwatch_log_group.archiver.name
    }
  }
}
