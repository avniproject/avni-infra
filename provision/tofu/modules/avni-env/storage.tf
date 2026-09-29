# ---------------------------------------------------------------------------
# Storage
#
# One bucket, two prefixes:
#   artefacts/    simulation.log, reports and run metadata — the harness
#                 requires an outbound path for these, and a closed
#                 environment otherwise has none.
#   deployables/  built jars, so a deploy never depends on whoever runs it
#                 having one locally. CI publishes here; laptop and CI deploys
#                 then pull from the same place.
#
# Reached through the S3 gateway endpoint, so none of this traffic crosses the
# NAT or attracts its per-GB processing charge.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "env" {
  bucket        = "${local.name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # test artefacts; the environment is disposable by design
  tags          = { Name = local.name }
}

resource "aws_s3_bucket_public_access_block" "env" {
  bucket                  = aws_s3_bucket.env.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "env" {
  bucket = aws_s3_bucket.env.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "env" {
  bucket = aws_s3_bucket.env.id

  # Run artefacts accumulate per run and are only interesting until analysed.
  rule {
    id     = "expire-run-artefacts"
    status = "Enabled"
    filter {
      prefix = "artefacts/"
    }
    expiration {
      days = 90
    }
  }

  # Deployables are small and their provenance matters for reading old runs,
  # so they live longer than artefacts.
  rule {
    id     = "expire-old-deployables"
    status = "Enabled"
    filter {
      prefix = "deployables/"
    }
    expiration {
      days = 365
    }
  }
}

# ---------------------------------------------------------------------------
# Media bucket — off by default.
#
# Presigning is local and nothing validates the bucket's existence, so the
# harness's requirement is a configured bucketName and a populated
# organisation mediaDirectory, not an actual bucket. Create one only as a
# deliberate choice.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "media" {
  count = var.enable_media_bucket ? 1 : 0

  bucket        = "${local.name}-media-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${local.name}-media" }
}

resource "aws_s3_bucket_public_access_block" "media" {
  count = var.enable_media_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.media[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# S3 access for avni-server
#
# An IAM USER with a static key, not the instance profile, and that is not an
# oversight. avni-server builds its S3 client with AWSStaticCredentialsProvider
# (AWSS3Service.java:39-43) and never consults the credential chain, so the
# instance profile this module otherwise relies on is invisible to it.
# Production solves it the same way.
#
# Scoped to this one bucket. The instance role keeps everything else, so the
# blast radius of this key is "the media bucket in a disposable account".
#
# Discovered the hard way: syncDetails is the first request of every simulated
# sync and it calls S3 to sync extension files, so an environment without this
# cannot serve a single sync.
# ---------------------------------------------------------------------------

resource "aws_iam_user" "media" {
  count = var.enable_media_bucket ? 1 : 0

  name = "${local.name}-media"
  tags = { Name = "${local.name}-media" }
}

data "aws_iam_policy_document" "media" {
  count = var.enable_media_bucket ? 1 : 0

  statement {
    sid     = "ListTheBucket"
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    # Listing is a bucket-level action, so it takes the bucket ARN rather than
    # an object path. Getting this wrong yields AccessDenied on extension sync
    # while object reads appear to work.
    resources = [aws_s3_bucket.media[0].arn]
  }

  statement {
    sid       = "ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.media[0].arn}/*"]
  }
}

resource "aws_iam_user_policy" "media" {
  count = var.enable_media_bucket ? 1 : 0

  name   = "${local.name}-media"
  user   = aws_iam_user.media[0].name
  policy = data.aws_iam_policy_document.media[0].json
}

# The secret is written to SSM rather than returned as an output, so it never
# enters the parity report, a log, or a terminal. Ansible reads it at run time
# the same way it reads the New Relic licence key.
resource "aws_iam_access_key" "media" {
  count = var.enable_media_bucket ? 1 : 0

  user = aws_iam_user.media[0].name
}

resource "aws_ssm_parameter" "media_access_key_id" {
  count = var.enable_media_bucket ? 1 : 0

  name  = "/avni/${var.environment}/media-access-key-id"
  type  = "SecureString"
  value = aws_iam_access_key.media[0].id
  tags  = { Name = "${local.name}-media-access-key-id" }
}

resource "aws_ssm_parameter" "media_secret_access_key" {
  count = var.enable_media_bucket ? 1 : 0

  name  = "/avni/${var.environment}/media-secret-access-key"
  type  = "SecureString"
  value = aws_iam_access_key.media[0].secret
  tags  = { Name = "${local.name}-media-secret-access-key" }
}
