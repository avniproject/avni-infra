# ---------------------------------------------------------------------------
# Security groups
#
# No rule anywhere admits 0.0.0.0/0. Every ingress is sourced from another
# security group, so the reachability graph is explicit: injector -> ALB ->
# app -> database, plus the Instance Connect Endpoint -> instances on 22.
# ---------------------------------------------------------------------------

resource "aws_security_group" "eice" {
  name        = "${local.name}-eice"
  description = "EC2 Instance Connect Endpoint. Reaches instances on 22; nothing reaches it."
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name}-eice" }
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Internal ALB. Internet-facing is deliberately not used."
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
  description = "Gatling injector. Inside the VPC so it resolves the private zone and is allowlistable in the WAF by CIDR."
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

resource "aws_vpc_security_group_ingress_rule" "alb_from_injector" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.injector.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Injector to ALB"
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
  etl_port = 8023
}
