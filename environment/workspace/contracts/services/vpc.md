# VPC and Security Groups (`services/vpc.md`)

- Provision one VPC (`aws_vpc`) with DNS support (`enable_dns_support = true`) and DNS hostnames (`enable_dns_hostnames = true`) enabled.
- Create at least two public subnets (`aws_subnet`, `map_public_ip_on_launch = true`) across `us-east-1a` and `us-east-1b`.
- Create at least two private subnets (`aws_subnet`, `map_public_ip_on_launch = false`) across `us-east-1a` and `us-east-1b`.
- Attach an Internet Gateway (`aws_internet_gateway`) to the VPC and associate (`aws_route_table_association`) a public route table (`0.0.0.0/0` -> Internet Gateway) with both public subnets.
- Associate (`aws_route_table_association`) a private route table (with no route to an Internet Gateway) with both private subnets.
- Create four distinct dedicated security groups (`aws_security_group`, four distinct security group IDs) enforcing least-privilege ingress and egress:
  - `alb`:
    - **Ingress**: TCP port `80` (`from_port = 80`, `to_port = 80`, `protocol = "tcp"`) from `0.0.0.0/0`.
    - **Egress**: TCP port `8080` (`from_port = 8080`, `to_port = 8080`, `protocol = "tcp"`) targeting the `ecs` security group or VPC CIDR (must not have explicit TCP/UDP egress rules allowing `0.0.0.0/0` or `::/0`).
  - `ecs`:
    - **Ingress**: restricted strictly to TCP port `8080` (`from_port = 8080`, `to_port = 8080`, `protocol = "tcp"`) from the `alb` security group ID (never `0.0.0.0/0`, `::/0`, or any CIDR block).
    - **Egress**: outbound traffic to the AWS control plane and data stores.
  - `rds`:
    - **Ingress**: restricted strictly to TCP port `5432` (`from_port = 5432`, `to_port = 5432`, `protocol = "tcp"`) from the `ecs` security group or VPC CIDR (never `0.0.0.0/0` or `::/0`).
    - **Egress**: no explicit outbound TCP/UDP egress rules (`egress = []`; passive data stores do not initiate outbound connections).
  - `valkey`:
    - **Ingress**: restricted strictly to TCP port `6379` (`from_port = 6379`, `to_port = 6379`, `protocol = "tcp"`) from the `ecs` security group or VPC CIDR (never `0.0.0.0/0` or `::/0`).
    - **Egress**: no explicit outbound TCP/UDP egress rules (`egress = []`; passive data stores do not initiate outbound connections).
- During `deploy.sh` convergence, revoke any out-of-band CIDR ingress rules added to `ecs` (which may only accept ingress from the `alb` security group ID), any public (`0.0.0.0/0` or `::/0`) ingress rules added to `rds` or `valkey`, any `0.0.0.0/0` or `::/0` egress rules added to `alb`, and any out-of-band egress rules added to `rds` or `valkey`.
- Tag the VPC, subnets, internet gateway, route tables, and security groups with `ClearLedgerDeployment = <resource_prefix>`.


