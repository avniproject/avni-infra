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

# THE BUCKET IS NOT MANAGED HERE, DELIBERATELY. It is created once by
# scripts/bootstrap-env-bucket.sh and read below with a data source.
#
# It used to be a module resource with force_destroy = true, commented "test
# artefacts; the environment is disposable by design". That conflated the
# bucket with its contents, and it defeated both of the bucket's own stated
# purposes:
#
#   deployables/ exists "so a deploy never depends on whoever runs it having
#   one locally" -- but destroying the bucket reinstates exactly that
#   dependency, and every rebuild then needs someone to re-upload a 112 MB jar
#   from their laptop. Observed, three rebuilds running.
#
#   artefacts/ exists because "the harness requires an outbound path for these,
#   and a closed environment otherwise has none" -- so destroying it takes the
#   run results with it. Those are the output of the whole exercise and the
#   most expensive thing here to lose.
#
# The bucket is an INPUT and an OUTPUT, not part of the environment. It joins
# the state bucket, the KMS key, the hosted zone and the baseline snapshot as
# something that outlives a destroy. Lifecycle rules and encryption are set by
# the bootstrap script, since the module no longer owns them.
#
# If this data source errors with "NoSuchBucket", the prerequisite has not been
# run. That is the fix, not a module bug.
data "aws_s3_bucket" "env" {
  bucket = "${local.name}-${data.aws_caller_identity.current.account_id}"
}

# ---------------------------------------------------------------------------
# Media bucket
#
# Unlike the environment bucket above, this one IS module-managed and dies with
# the environment. Its contents are extensions and media belonging to a
# specific dataset, not inputs or outputs that outlive a rebuild. Revisit if
# extensions ever become part of a durable org configuration.
#
# Not optional despite the variable name: syncDetails calls S3 to list
# extension files, so an environment without this cannot serve a single sync.
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
