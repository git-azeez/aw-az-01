# VPC and Security Groups (`services/vpc.md`)

- Provision one VPC (`aws_vpc`) with DNS support (`enable_dns_support = true`) and DNS hostnames (`enable_dns_hostnames = true`) enabled.
- Create at least two public subnets (`aws_subnet`, `map_public_ip_on_launch = true`) across `us-east-1a` and `us-east-1b`.
- Create at least two private subnets (`aws_subnet`, `map_public_ip_on_launch = false`) across `us-east-1a` and `us-east-1b`.
- Attach an Internet Gateway (`aws_internet_gateway`) to the VPC and associate a public route table (`0.0.0.0/0` -> Internet Gateway) with both public subnets.
- Associate a private route table with both private subnets.
- Create four dedicated security groups (`aws_security_group`):
  - `alb`: allows inbound TCP `80` from `0.0.0.0/0` and outbound traffic to the ECS security group on TCP `8080`.
  - `ecs`: allows inbound TCP `8080` only from the `alb` security group (never `0.0.0.0/0` on `8080`) and allows outbound traffic.
  - `rds`: allows inbound TCP `5432` from the `ecs` security group or VPC CIDR (never `0.0.0.0/0` on `5432`).
  - `valkey`: allows inbound TCP `6379` from the `ecs` security group or VPC CIDR (never `0.0.0.0/0` on `6379`).
- Tag the VPC, subnets, internet gateway, route tables, and security groups with `ClearLedgerDeployment = <resource_prefix>`.
