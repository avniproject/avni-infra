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

# ebs-gp2, not ebs-gp3, and deliberately so. Canonical publishes a gp3 variant
# only from 24.04; for 22.04 the path simply does not exist, and the failure is
# an unhelpful "couldn't find resource" on the data source rather than anything
# naming the volume type.
#
# It costs nothing: this selects which published AMI to launch, not what the
# instance ends up with. root_block_device below sets volume_type = "gp3"
# explicitly, so every host runs on gp3 regardless. Do not "fix" this to gp3
# without also moving ubuntu_release to 24.04, which var.ubuntu_release
# explains is not free.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/${var.ubuntu_release}/stable/current/arm64/hvm/ebs-gp2/ami-id"
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
        public        = false
      }
    },
    var.enable_etl ? {
      "avni-etl" = {
        instance_type = var.etl_instance_class
        root_volume   = 40
        sg            = aws_security_group.etl.id
        public        = false
      }
    } : {},
    var.enable_injector ? {
      "injector" = {
        instance_type = var.injector_instance_class
        root_volume   = 40
        sg            = aws_security_group.injector.id
        # The only host in a public subnet. It needs a stable address of its
        # own because that address is what gets enrolled in the ALB security
        # group and the WAF IP set; from a private subnet its traffic would
        # leave via the NAT gateway, making the NAT's address the one to enrol
        # and charging NAT data processing for every request of every run.
        public = true
      }
    } : {},
    var.enable_loader ? {
      "loader" = {
        instance_type = var.loader_instance_class
        root_volume   = 40
        sg            = aws_security_group.loader.id
        public        = false
      }
    } : {},
  )
}

resource "aws_instance" "host" {
  for_each = local.hosts

  ami           = data.aws_ssm_parameter.ubuntu.value
  instance_type = each.value.instance_type

  subnet_id              = each.value.public ? aws_subnet.public[0].id : aws_subnet.private[0].id
  vpc_security_group_ids = [each.value.sg]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = local.key_name

  # Nothing under test gets a public IP. The injector does, because its subnet
  # routes 0.0.0.0/0 at the internet gateway and an instance with no public
  # address cannot use one — without this it would have no egress at all for
  # apt and the New Relic agent. The elastic IP below then replaces this
  # auto-assigned address with a stable one, and that is the address to enrol.
  #
  # Either way SSH is the Instance Connect Endpoint, which authorises by IAM
  # rather than by network position, and no host has an inbound rule from a
  # public address.
  associate_public_ip_address = each.value.public

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

# The injector's own address, which is what belongs in injector_allowed_cidrs
# as a /32 for a run driven from inside the VPC. Deliberately not wired into
# that variable automatically: enrolment is the step that proves someone
# decided which addresses may reach an unauthenticated server.
resource "aws_eip" "injector" {
  count = var.enable_injector ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.host["injector"].id
  tags     = { Name = "${local.name}-injector" }

  depends_on = [aws_internet_gateway.this]
}
