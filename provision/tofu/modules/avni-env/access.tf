# ---------------------------------------------------------------------------
# Access path
#
# The whole point of this file: reach instances that have no public IP and no
# inbound rule. An EC2 Instance Connect Endpoint tunnels SSH through the AWS
# API, so authorisation is IAM rather than network position — a stronger
# control than any address allowlist, and it works from anywhere with
# credentials, including CI.
#
# Ansible uses it as a ProxyCommand and addresses hosts by instance ID:
#   ansible_ssh_common_args=-o ProxyCommand="aws ec2-instance-connect \
#     open-tunnel --instance-id %h --profile <profile>"
#
# Prove a human can reach a bare instance through this before building
# anything on top of it (plan task 2.2) — it is the task most likely to
# consume an unexpected day.
# ---------------------------------------------------------------------------

resource "aws_ec2_instance_connect_endpoint" "this" {
  subnet_id          = aws_subnet.private[0].id
  security_group_ids = [aws_security_group.eice.id]

  # false: traffic reaches the instance from the endpoint's ENI, so the
  # instance security group references the endpoint's group rather than an
  # ever-changing client address.
  preserve_client_ip = false

  tags = { Name = local.name }
}

# ---------------------------------------------------------------------------
# Instance role
#
# Deliberately narrow. Production templates long-lived IAM user access keys
# onto the box (provision/server/server.tf:15-17); this uses an instance
# profile so there is no static credential to leak or rotate.
#
# The explicit denies are how "outbound side effects impossible" becomes
# structural rather than a matter of which credentials Ansible happens to
# write. MessageSenderJob runs on a fixed delay and sends to whatever the
# database says are real recipients; with no SNS or SES permission it cannot,
# regardless of configuration mistakes.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
  tags               = { Name = "${local.name}-instance" }
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid    = "ReadDeployables"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.env.arn,
      "${aws_s3_bucket.env.arn}/*",
    ]
  }

  statement {
    sid    = "WriteRunArtefacts"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.env.arn}/artefacts/*"]
  }

  statement {
    sid    = "Observability"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyOutboundSideEffects"
    effect = "Deny"
    actions = [
      "sns:*",
      "ses:*",
      "pinpoint:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "${local.name}-instance"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}
