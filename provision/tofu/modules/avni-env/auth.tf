# ---------------------------------------------------------------------------
# Cognito — off by default, and probably never needed.
#
# B1 (AVNI_IDP_TYPE=none) is decided, and B2 — the auth-cost measurement that
# was the only reason to stand Cognito up — is deferred: it needs a working
# Cognito path, and the simulation now strips Cognito entirely, so taking the
# measurement later would mean restoring deliberately deleted code. Auth
# ordering is simply F4 (open the deploy path) then B1; nothing has to happen
# before the cutover.
#
# Retained because it costs nothing to keep and an un-deferred B2 would want it.
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
