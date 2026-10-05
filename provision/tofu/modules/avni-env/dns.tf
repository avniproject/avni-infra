# ---------------------------------------------------------------------------
# DNS and the certificate
#
# A PUBLIC hosted zone, delegated from avniproject.org.
#
# This was a private zone, chosen precisely because it needs no registration
# and no delegation and never touches public DNS. F4 changed the requirement:
# the customer has asked to run the injector from a local machine, and a local
# machine cannot resolve a private zone. So the name is public and the control
# on reachability is the address allowlist instead (see injector_allowed_cidrs).
#
# THE ZONE IS NOT MANAGED HERE, DELIBERATELY. It is created once by
# scripts/bootstrap-dns-zone.sh and read below with a data source.
#
# It used to be a module resource, and that was wrong in a way that only
# surfaces on the REBUILD rather than the first build: `tofu destroy` took the
# zone with it, a rebuild created a new one with NEW name servers, and the NS
# delegation in the production account still pointed at the old four. The name
# would resolve nowhere, aws_acm_certificate_validation would hang for ~75
# minutes and fail, and the cause would be two accounts away from the symptom.
#
# So the zone joins the state bucket, the KMS key and the baseline snapshot as
# something that OUTLIVES the environment. Destroy and rebuild freely; the
# delegation stays valid because the name servers never change.
#
# Delegation is a one-time manual step in the PRODUCTION account, which owns
# avniproject.org. bootstrap-dns-zone.sh prints the NS values to add. Until
# that exists the name does not resolve and the certificate below sits pending.
#
# If this data source errors with "no matching Route 53 Zone found", the
# prerequisite has not been run -- that is the fix, not a module bug.
#
# Note the deploy path still does not use any of this. Ansible reaches hosts by
# instance ID through the Instance Connect Endpoint. This exists so both
# injector positions resolve the same BASE_URL — identical from either
# position, which is what makes runs comparable at all.
# ---------------------------------------------------------------------------

data "aws_route53_zone" "this" {
  name         = var.zone_name
  private_zone = false
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.zone_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# Certificate
#
# Production terminates HTTPS at the ALB and termination costs something per
# request, so this is parity rather than hygiene. Issued here and validated
# through the zone above; pass acm_certificate_arn to use an imported one
# instead.
#
# create_before_destroy because a certificate in use by a listener cannot be
# replaced in place.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "this" {
  count = var.acm_certificate_arn == null ? 1 : 0

  domain_name       = var.zone_name
  validation_method = "DNS"

  tags = { Name = local.name }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.acm_certificate_arn == null ? {
    for o in aws_acm_certificate.this[0].domain_validation_options :
    o.domain_name => o
  } : {}

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60

  allow_overwrite = true
}

# Blocks until the certificate is issued, so the listener is never created
# against a pending one. This is where a missing NS delegation surfaces: it
# times out rather than failing fast, which is worth knowing before blaming
# the module.
resource "aws_acm_certificate_validation" "this" {
  count = var.acm_certificate_arn == null ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

locals {
  certificate_arn = var.acm_certificate_arn == null ? aws_acm_certificate_validation.this[0].certificate_arn : var.acm_certificate_arn
}
