locals {
  vpc_cidr             = "10.60.0.0/16"
  public_subnet_cidrs  = ["10.60.0.0/24", "10.60.1.0/24"]
  private_subnet_cidrs = ["10.60.10.0/24", "10.60.11.0/24"]
}

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.prefix}-igw" })
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.prefix}-public-${count.index + 1}", Tier = "public" })
}

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${local.prefix}-private-${count.index + 1}", Tier = "private" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.prefix}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${local.prefix}-private-rt" })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Security groups (rules are inline so Terraform owns them exclusively) ---

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb"
  description = "ClearLedger ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress to the ECS tasks only (VPC CIDR avoids a SG<->SG dependency cycle).
  egress {
    description = "To ECS tasks"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = merge(local.tags, { Name = "${local.prefix}-alb" })
}

resource "aws_security_group" "ecs" {
  name        = "${local.prefix}-ecs"
  description = "ClearLedger API tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API port from ALB only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "AWS control plane (HTTPS)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "AWS control plane (local endpoint)"
    from_port   = 4566
    to_port     = 4566
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    description = "Valkey"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = merge(local.tags, { Name = "${local.prefix}-ecs" })
}

resource "aws_security_group" "rds" {
  name        = "${local.prefix}-rds"
  description = "ClearLedger PostgreSQL"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress = []

  tags = merge(local.tags, { Name = "${local.prefix}-rds" })
}

resource "aws_security_group" "valkey" {
  name        = "${local.prefix}-valkey"
  description = "ClearLedger Valkey"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Valkey from ECS"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress = []

  tags = merge(local.tags, { Name = "${local.prefix}-valkey" })
}
