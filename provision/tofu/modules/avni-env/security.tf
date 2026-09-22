# ---------------------------------------------------------------------------
# Security groups
#
# No rule anywhere admits 0.0.0.0/0. Every ingress is sourced from another
# security group — except the ALB's, which is sourced from the enrolled
# injector addresses, because the ALB is internet-facing (F4) and the injector
# may be a laptop. The reachability graph stays explicit: enrolled addresses ->
# ALB -> app -> database, plus the Instance Connect Endpoint -> instances
# on 22.
# ---------------------------------------------------------------------------

resource "aws_security_group" "eice" {
  name        = "${local.name}-eice"
  description = "EC2 Instance Connect Endpoint. Reaches instances on 22; nothing reaches it."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-eice" }
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Internet-facing ALB. Ingress only from enrolled injector addresses; this is the whole isolation control for the application port."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-alb" }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "avni-server host"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-app" }
}

resource "aws_security_group" "etl" {
  name        = "${local.name}-etl"
  description = "avni-etl host"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-etl" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "RDS. Reachable only from the app, ETL and loader hosts."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-db" }
}

resource "aws_security_group" "injector" {
  name        = "${local.name}-injector"
  description = "Gatling injector. In a public subnet with its own elastic IP, so the address the ALB and WAF see is its own."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-injector" }
}

resource "aws_security_group" "loader" {
  name        = "${local.name}-loader"
  description = "Dataset loader. Exists only around the bulk load."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-loader" }
}

# -- SSH, only ever from the endpoint -------------------------------------

resource "aws_vpc_security_group_egress_rule" "eice_to_hosts" {
  for_each = {
    app      = aws_security_group.app.id
    etl      = aws_security_group.etl.id
    injector = aws_security_group.injector.id
    loader   = aws_security_group.loader.id
  }
  security_group_id            = aws_security_group.eice.id
  referenced_security_group_id = each.value
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "Instance Connect tunnel to ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "hosts_from_eice" {
  for_each = {
    app      = aws_security_group.app.id
    etl      = aws_security_group.etl.id
    injector = aws_security_group.injector.id
    loader   = aws_security_group.loader.id
  }
  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.eice.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  description                  = "SSH via Instance Connect Endpoint only"
}

# -- The request path ------------------------------------------------------

# One rule per enrolled address, and no security-group-referenced alternative
# even for the in-VPC injector. It sits in a public subnet and reaches the ALB
# by its public name, so the traffic leaves through the internet gateway and
# arrives with the injector's elastic IP as its source — a group reference
# would not match it. The same addresses populate the WAF IP set, from the same
# variable, because two lists that must agree will not.
#
# An empty list means nothing reaches the application port. That is the default,
# and it is the safe one.
resource "aws_vpc_security_group_ingress_rule" "alb_from_injector" {
  for_each = toset(var.injector_allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Enrolled injector address"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = local.app_port
  to_port                      = local.app_port
  ip_protocol                  = "tcp"
  description                  = "ALB to avni-server"
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.app_port
  to_port                      = local.app_port
  ip_protocol                  = "tcp"
  description                  = "avni-server from ALB"
}

# -- Database --------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "db_from" {
  for_each = {
    app    = aws_security_group.app.id
    etl    = aws_security_group.etl.id
    loader = aws_security_group.loader.id
  }
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from ${each.key}"
}

# -- Egress ----------------------------------------------------------------
#
# Instances need general outbound: apt and download.newrelic.com at deploy
# time, and the New Relic agent reporting continuously at run time. Blocking
# outbound side effects (SNS, SES, third-party integrations) is done at the IAM
# boundary and by omitting credentials, not here — a CIDR-based egress rule
# cannot distinguish New Relic's collector from Glific's API.

resource "aws_vpc_security_group_egress_rule" "hosts_egress" {
  for_each = {
    app      = aws_security_group.app.id
    etl      = aws_security_group.etl.id
    injector = aws_security_group.injector.id
    loader   = aws_security_group.loader.id
  }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound for packages and New Relic telemetry"
}

locals {
  app_port = 8021
}

# No app -> ETL security group rule, deliberately. Nothing reaches avni-etl over
# the network: `avni_server_etl_service_origin` is set in group_vars but
# referenced by no role template, and the nginx `/etl` proxy assumes the two run
# on the same host, which this environment does not do. ETL's contention with
# sync is for database I/O, which is the thing being measured.

