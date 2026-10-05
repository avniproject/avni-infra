# ---------------------------------------------------------------------------
# Cognito — off by default. The environment starts closed and stays closed.
#
# B1 (AVNI_IDP_TYPE=none) is decided and every run uses it, so auth ordering is
# simply F4 (open the deploy path and the allowlist) then B1. There is no
# cutover to stage.
#
# B2 — the auth-cost measurement a pool here would serve — is deferred BY
# CHOICE. The reason recorded here previously was wrong and is worth correcting
# rather than repeating: it is not that the simulation strips Cognito, because
# AUTH_MODE=cognito is live behind a flag with its own CognitoHelper, and the
# harness records B2 as available. It is that the measurement can be taken
# whenever it is wanted, and never passing through an open posture is worth
# more than taking it early.
#
# When it is wanted it runs here, not against staging or prerelease: an offset
# measured on a different instance class against a different dataset is not the
# offset this environment's results need adjusting by. Set enable_cognito,
# provision users, take the two runs, unset it.
#
# Retained because it costs nothing to keep and makes that a flag flip.
#
# Schema attributes are immutable once the pool exists. Getting them wrong
# means replacing the pool, so they mirror production's exactly.
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "this" {
  count = var.enable_cognito ? 1 : 0

  name = local.name

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = false
    require_symbols   = false
    require_uppercase = false
  }

  dynamic "schema" {
    for_each = [
      "organisationId", "organisationName", "catchmentId",
      "isUser", "isAdmin", "isOrganisationAdmin",
    ]
    content {
      name                = schema.value
      attribute_data_type = "String"
      mutable             = true
    }
  }

  tags = { Name = local.name }
}

resource "aws_cognito_user_pool_client" "this" {
  count = var.enable_cognito ? 1 : 0

  name         = "openchs"
  user_pool_id = aws_cognito_user_pool.this[0].id

  explicit_auth_flows = [
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
