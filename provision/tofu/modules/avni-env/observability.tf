# ---------------------------------------------------------------------------
# Observability
#
# F1 is the gating requirement: without it the whole exercise produces
# findings nobody can act on. The database side is configured in database.tf
# (pg_stat_statements, slow query log, Performance Insights, Enhanced
# Monitoring); this file covers logs, alarms and cost.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/avni/${var.environment}/avni-server"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${local.name}-app" }
}

resource "aws_cloudwatch_log_group" "etl" {
  count = var.enable_etl ? 1 : 0

  name              = "/avni/${var.environment}/avni-etl"
  retention_in_days = var.log_retention_days
  tags              = { Name = "${local.name}-etl" }
}

# This alarm matters more than it usually would. Storage autoscaling is
# deliberately disabled to protect I/O parity, which means a filling volume is
# a hard stop rather than a silent grow — the instance enters storage-full and
# stops serving. Catch it before that. Note the working copy grows during runs
# that exercise the push path, so free space moves within a campaign.
resource "aws_cloudwatch_metric_alarm" "free_storage" {
  alarm_name          = "${local.name}-free-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"

  # 15% of allocated, in bytes.
  threshold = var.db_allocated_storage * 1024 * 1024 * 1024 * 0.15

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.this.identifier
  }

  alarm_description = "Autoscaling is off by design; a full volume stops the instance. Rebuild or prune before this fires."
  tags              = { Name = "${local.name}-free-storage" }
}

# Storage dominates this environment's cost — ~250 GiB of gp3 is about USD 33
# a month whether anything runs or not, against roughly USD 6 for the database
# at 26 hours. So the budget is mostly watching for an environment left up.
resource "aws_budgets_budget" "this" {
  name         = local.name
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
}
