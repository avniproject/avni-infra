# ---------------------------------------------------------------------------
# Network
#
# Shape: two private subnets carrying everything that matters (instances, RDS,
# the internal ALB) and two public subnets whose only job is to host the NAT
# gateway. Nothing under test has a public IP or an inbound rule.
#
# Two AZs even though the database is single-AZ: an RDS subnet group requires
# subnets in at least two, and an ALB requires at least two. The database
# itself still lands in one.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # /20 per subnet out of a /16: 4094 usable addresses each, far more than
  # needed, but the address space is free and resizing a subnet is not.
  public_cidrs  = [cidrsubnet(var.vpc_cidr, 4, 0), cidrsubnet(var.vpc_cidr, 4, 1)]
  private_cidrs = [cidrsubnet(var.vpc_cidr, 4, 2), cidrsubnet(var.vpc_cidr, 4, 3)]

  name = "avni-${var.environment}"
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both required for the Route53 private hosted zone to resolve inside the VPC.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  count = length(local.public_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # The NAT gateway needs a public IP; nothing else is placed here.
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${local.azs[count.index]}" }
}

resource "aws_subnet" "private" {
  count = length(local.private_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

# ---------------------------------------------------------------------------
# Egress
#
# NAT is required, not optional. Security groups permit egress by default, but
# that is not a route: a private subnet has no path out, and an instance with no
# public IP cannot use an internet gateway even where one is routed, because the
# gateway does 1:1 NAT and has no address to map to.
#
# What actually needs to leave: apt and download.newrelic.com at deploy time,
# and the New Relic agent reporting to its collector continuously at run time.
# That last one is why this cannot be a deploy-window-only arrangement — making
# the agent mandatory (for parity, since production runs it and it costs the JVM
# something) made egress a runtime dependency.
#
# One NAT, not one per AZ. The environment is single-AZ for the database and is
# destroyed between runs; at USD 0.045/hr a NAT that only exists during runs
# costs about USD 1/month.
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = local.name }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${local.name}-private" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# S3 gateway endpoint: free, and it keeps artefact and deployable traffic off
# the NAT and out of its per-GB processing charge.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]

  tags = { Name = "${local.name}-s3" }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
