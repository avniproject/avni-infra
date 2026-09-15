# ---------------------------------------------------------------------------
# Compute
#
# Every instance is tagged Environment and Role, because the Ansible inventory
# is an amazon.aws.aws_ec2 dynamic plugin keyed on exactly these. A disposable
# environment has no stable instance IDs to hardcode — 3.2 mandates a
# destroy-and-reapply before anything depends on it — so tags are the only
# durable handle.
#
# Fixed-performance Graviton throughout. Compatibility was checked against the
# dependency graph rather than assumed: avni-server and avni-etl are pure Java
# with no native artefacts, GraalVM JS belongs to the separate avni-rule-server
# subproject, the JDK comes from apt where arm64 is available, and the New
# Relic agent is architecture-neutral.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_release}/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "break_glass" {
  count = var.ssh_public_key == null ? 0 : 1

  key_name   = local.name
  public_key = var.ssh_public_key
  tags       = { Name = local.name }
}

locals {
  key_name = var.ssh_public_key == null ? null : aws_key_pair.break_glass[0].key_name

  # One place to change how every host is built. root_volume is generous
  # relative to production's 40 GB because request logging is high volume —
  # AuthenticationFilter logs twice per request including the query string.
  hosts = merge(
    {
      "avni-server" = {
        instance_type = var.app_instance_class
        root_volume   = 60
        sg            = aws_security_group.app.id
      }
    },
    var.enable_etl ? {
      "avni-etl" = {
        instance_type = var.etl_instance_class
        root_volume   = 40
        sg            = aws_security_group.etl.id
      }
    } : {},
    var.enable_injector ? {
      "injector" = {
        instance_type = var.injector_instance_class
        root_volume   = 40
        sg            = aws_security_group.injector.id
      }
    } : {},
    var.enable_loader ? {
      "loader" = {
        instance_type = var.loader_instance_class
        root_volume   = 40
        sg            = aws_security_group.loader.id
      }
    } : {},
  )
}

resource "aws_instance" "host" {
  for_each = local.hosts

  ami           = data.aws_ssm_parameter.ubuntu.value
  instance_type = each.value.instance_type

  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [each.value.sg]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = local.key_name

  # No public IP. Reached through the Instance Connect Endpoint, which
  # authorises by IAM rather than by network position.
  associate_public_ip_address = false

  root_block_device {
    volume_size           = each.value.root_volume
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  tags = {
    Name        = "${local.name}-${each.key}"
    Environment = var.environment
    Role        = each.key
  }

  lifecycle {
    # The AMI moves as Canonical publishes; a new one should not silently
    # replace a host mid-campaign. Rebuild deliberately instead.
    ignore_changes = [ami]
  }
}
