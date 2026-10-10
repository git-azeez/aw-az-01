resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.prefix}-vpc" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.prefix}-public-${count.index == 0 ? "a" : "b"}", Tier = "public" }
}

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.private_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.prefix}-private-${count.index == 0 ? "a" : "b"}", Tier = "private" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-public-rt" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-private-rt" }
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

# ---------------------------------------------------------------------------
# Security groups. Rules are declared inline so that Terraform is authoritative
# over the complete rule set and removes out-of-band additions on every apply.
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.prefix}-alb"
  description = "ClearLedger ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.prefix}-alb" }

  ingress {
    description = "HTTP from the internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Forward to ECS tasks inside the VPC"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }
}

resource "aws_security_group" "ecs" {
  name        = "${local.prefix}-ecs"
  description = "ClearLedger API tasks"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.prefix}-ecs" }

  ingress {
    description     = "API port from the ALB only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "PostgreSQL inside the VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    description = "Valkey inside the VPC"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    description = "AWS control plane / service endpoints (HTTPS)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Local AWS control plane endpoint"
    from_port   = 4566
    to_port     = 4566
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.prefix}-rds"
  description = "ClearLedger PostgreSQL"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.prefix}-rds" }

  ingress {
    description     = "PostgreSQL from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress = []
}

resource "aws_security_group" "valkey" {
  name        = "${local.prefix}-valkey"
  description = "ClearLedger Valkey cache"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.prefix}-valkey" }

  ingress {
    description     = "Valkey from ECS tasks"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress = []
}
