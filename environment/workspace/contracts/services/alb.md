# Application Load Balancer (`services/alb.md`)

- Provision an internet-facing Application Load Balancer (`aws_lb`, `load_balancer_type = "application"`, `internal = false`) attached to the two public subnets and the `alb` security group.
- Provision an HTTP target group (`aws_lb_target_group`) on port `8080` (`protocol = "HTTP"`, `target_type = "ip"`) with a health check configured for:
  - `path = "/health/ready"`
  - `protocol = "HTTP"`
  - `matcher = "200"`
- Provision an HTTP listener (`aws_lb_listener`) on port `80` (`protocol = "HTTP"`) with a default `forward` action targeting the target group.
- Expose `http://aws:80` (or `http://<alb_dns_name>`) as `service_url` in `manifest.json`.
