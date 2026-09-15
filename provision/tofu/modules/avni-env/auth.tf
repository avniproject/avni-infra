# ---------------------------------------------------------------------------
# Cognito — present only while the environment is open.
#
# The harness measures the auth-cost offset (B2) against a working Cognito
# path, and that measurement has to happen *before* the environment closes to
# AVNI_IDP_TYPE=none, because afterwards there is nothing to measure against.
# Ordering is B2, then the deploy path opens (F4), then B1 closes it.
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
