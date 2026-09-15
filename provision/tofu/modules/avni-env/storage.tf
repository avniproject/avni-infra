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
