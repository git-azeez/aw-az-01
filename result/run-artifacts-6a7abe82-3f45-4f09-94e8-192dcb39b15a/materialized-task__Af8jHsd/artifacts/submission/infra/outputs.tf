locals {
  manifest = {
    resource_prefix = local.prefix
    region          = local.region
    service_url     = "http://${aws_lb.main.dns_name}"
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
      db_name      = local.cfg.db_name
      username     = local.cfg.db_username
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
      projector = {
        function_name = aws_lambda_function.projector.function_name
        function_arn  = aws_lambda_function.projector.arn
      }
      outbox_relay = {
        function_name = aws_lambda_function.relay.function_name
        function_arn  = aws_lambda_function.relay.arn
      }
      audit_archiver = {
        function_name = aws_lambda_function.archiver.function_name
        function_arn  = aws_lambda_function.archiver.arn
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
      outbox_schedule_name  = aws_scheduler_schedule.relay.name
      outbox_schedule_arn   = aws_scheduler_schedule.relay.arn
      archive_schedule_name = aws_scheduler_schedule.archiver.name
      archive_schedule_arn  = aws_scheduler_schedule.archiver.arn
    }
    auth = {
      user_pool_id               = aws_cognito_user_pool.main.id
      user_pool_arn              = aws_cognito_user_pool.main.arn
      issuer_url                 = local.issuer_url
      token_endpoint             = local.token_endpoint
      resource_server_identifier = aws_cognito_resource_server.clearledger.identifier
      clients = {
        for k, s in local.client_scopes : k => {
          client_id     = aws_cognito_user_pool_client.client[k].id
          client_secret = aws_cognito_user_pool_client.client[k].client_secret
          scope         = s
        }
      }
    }
    iam = {
      ecs_execution_role_arn = aws_iam_role.role["ecs_execution"].arn
      ecs_task_role_arn      = aws_iam_role.role["ecs_task"].arn
      projector_role_arn     = aws_iam_role.role["projector"].arn
      relay_role_arn         = aws_iam_role.role["relay"].arn
      archiver_role_arn      = aws_iam_role.role["archiver"].arn
      scheduler_role_arn     = aws_iam_role.role["scheduler"].arn
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

output "manifest" {
  value     = local.manifest
  sensitive = true
}

output "database_url" {
  value     = local.database_url
  sensitive = true
}
