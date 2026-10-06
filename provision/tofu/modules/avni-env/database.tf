# ---------------------------------------------------------------------------
# Database
#
# The environment's defining constraint lives here. Production runs gp3 at a
# flat 3000 IOPS / 125 MiB/s, and the harness requires I/O parity — so the
# volume must stay under 400 GiB, where RDS restripes across four volumes and
# hands out 12000 / 500. Four times production's storage performance would mask
# the bottleneck this environment exists to find.
#
# Storage autoscaling is deliberately absent. Note this is a *deviation*:
# production has it enabled (MaxAllocatedStorage 1000 on both primary and
# replica), which means production's own I/O ceiling could move. The rig wants
# a fixed one precisely because production's is not.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = local.name }
}

resource "aws_db_parameter_group" "this" {
  name   = local.name
  family = "postgres16"

  # F1: the environment must be able to explain why it slowed down, not only
  # report that it did.
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,pg_prewarm"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "pg_stat_statements.track"
    value = "all"
  }

  # Slow query log, matched to production 1 Oct 2026. This was 1000ms, described
  # in this comment as "a starting point, not a considered threshold". Production's
  # considered threshold is 5000ms, so that is what this now uses.
  #
  # **It is not in production's parameter group.** It is set with ALTER DATABASE,
  # which `describe-db-parameters` cannot see — a group-to-group comparison reports
  # production as having no slow query log at all, which is how this was first
  # recorded and was wrong. Only `pg_settings` shows it, as `source = database`.
  # Worth remembering whenever parity is checked by comparing groups alone.
  #
  # 1000ms also costs more than it looks on a rig: every statement between one and
  # five seconds becomes a log write that production would not make, at load-test
  # request rates, competing for the same IOPS being measured.
  parameter {
    name  = "log_min_duration_statement"
    value = tostring(var.db_log_min_duration_ms)
  }

  # Production peaks at 122-130 connections, above the ~100 Tomcat JDBC default
  # that caused the July pool exhaustion. Headroom here is deliberate: the pool
  # size is set explicitly on the app side (Ansible 9.6) and the database should
  # not be the thing that caps it first.
  parameter {
    name         = "max_connections"
    value        = var.db_max_connections
    apply_method = "pending-reboot"
  }

  # ---------------------------------------------------------------------------
  # Timeouts, matched to production 1 Oct 2026.
  #
  # Both were unset or effectively unset here, and both matter MORE on a load rig
  # than in production: this is precisely where a pathological query or an
  # abandoned transaction appears. An un-killed statement holds its snapshot,
  # which blocks vacuum, which carries bloat into the NEXT run -- so the damage
  # outlives the run that caused it.
  # ---------------------------------------------------------------------------

  # Production: 7200000. Was unset, so a runaway query here ran forever.
  parameter {
    name  = "statement_timeout"
    value = tostring(var.db_statement_timeout_ms)
  }

  # Production: 3600000. Was the engine default of 86400000 -- an injector that
  # dies mid-run left a transaction open for a day.
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = tostring(var.db_idle_in_transaction_timeout_ms)
  }

  # Left on for realism. Production has it on, and an autovacuum storm during a
  # run is a genuine production failure mode worth catching rather than
  # engineering away. Record it as a known source of run-to-run variance.
  parameter {
    name  = "autovacuum"
    value = var.db_autovacuum ? "1" : "0"
  }

  tags = { Name = local.name }

  lifecycle {
    create_before_destroy = true
  }
}

# Enhanced Monitoring reports OS-level metrics the CloudWatch RDS namespace
# does not, which matters when the question is whether I/O or CPU binds first.
data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier = local.name

  engine         = "postgres"
  engine_version = var.db_engine_version

  # Pinned, because the provider defaults this to true and a rig whose value is
  # comparability cannot have AWS change its query planner mid-campaign. Same
  # reasoning as max_allocated_storage being left unset: the plan's standing
  # rule is that the measured characteristics stay stable for the life of the
  # environment. Upgrade deliberately, re-baseline, and note it.
  auto_minor_version_upgrade = false
  instance_class             = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  # Deliberately NOT set. Setting max_allocated_storage enables autoscaling,
  # which could grow the volume past 400 GiB mid-campaign and silently restripe
  # it to four times production's IOPS — with nothing in the Gatling report to
  # show for it. Leaving it unset is the whole point; do not add it later as a
  # well-meant safety net. FreeStorageSpace is alarmed instead (observability.tf).
  # max_allocated_storage = <never>

  db_name  = "openchs"
  username = "openchs"

  # The password is generated by AWS and held in Secrets Manager, so it never
  # enters OpenTofu state. Production carries a literal password = "password"
  # in its Terraform; this does not.
  manage_master_user_password = true

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  enabled_cloudwatch_logs_exports = ["postgresql"]

  # Rebuild path: restore the harness's baseline snapshot rather than starting
  # empty. That snapshot is created and guarded by the harness and is NOT
  # managed here — a tofu destroy must not be able to take it.
  snapshot_identifier = var.restore_from_snapshot

  # The environment is disposable by design, so destroy must work. A final
  # snapshot is still taken by default, because a run's database is sometimes
  # worth keeping long enough to ask it a question.
  deletion_protection       = false
  skip_final_snapshot       = !var.retain_on_destroy
  final_snapshot_identifier = var.retain_on_destroy ? "${local.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}" : null

  apply_immediately = true

  tags = { Name = local.name }

  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }
}

# Production has a read replica — and it is a db.t4g.medium, half the primary's
# memory, running its own parameter group. Matching that shape matters for
# read-path fidelity if the replica is in scope at all.
resource "aws_db_instance" "replica" {
  count = var.enable_read_replica ? 1 : 0

  identifier          = "${local.name}-read"
  replicate_source_db = aws_db_instance.this.identifier
  instance_class      = var.replica_instance_class

  storage_encrypted      = true
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  skip_final_snapshot = true
  apply_immediately   = true

  tags = { Name = "${local.name}-read" }
}

# **Rotation every 7 days breaks the app server, silently and only under load.**
#
# `manage_master_user_password` has RDS create and own the secret, and RDS
# defaults it to a 7-day rotation. avni-server does not read Secrets Manager:
# configure/Makefile fetches the password at playbook time and writes it into
# /etc/avni_server_appserver.conf, so what the server holds is a point-in-time
# copy that a rotation invalidates.
#
# The failure mode is the problem rather than the frequency. Connections already
# in the Hikari pool keep working, so /ping and /idp-details answer 200 and light
# traffic is served correctly; only a NEW connection fails. On 6 Oct 2026 a
# rotation at 09:54 left the 900 s run (1.2 devices in flight) with zero failures
# and the 75 s run half an hour later (about 18 in flight) with 38 HTTP 500s.
# Nothing reports the fault until load happens to force the pool to grow, and
# when it does it looks like an application bug.
#
# 365 days does not fix the design -- it makes the window longer than any
# environment this module builds, which is disposable and rebuilt from a
# snapshot. The real fix is for the server to read the secret when it connects.
#
# **rotate_immediately is false deliberately.** It defaults to TRUE, and leaving
# it so would rotate on apply -- causing exactly the outage this resource exists
# to prevent, at a moment nobody associates with Terraform.
resource "aws_secretsmanager_secret_rotation" "db_master" {
  secret_id          = aws_db_instance.this.master_user_secret[0].secret_arn
  rotate_immediately = false

  rotation_rules {
    automatically_after_days = var.db_secret_rotation_days
  }
}
