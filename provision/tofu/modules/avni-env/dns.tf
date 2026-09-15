# ---------------------------------------------------------------------------
# DNS
#
# A private hosted zone, which needs no registration and no delegation: it
# resolves only inside associated VPCs and never touches public DNS. That
# sidesteps avniproject.org living in the production account entirely.
#
# Route53 matches most-specific-first, so a zone for loadtest.avniproject.org
# shadows only names at or below it — app.avniproject.org still resolves
# publicly from inside this VPC. A zone for avniproject.org itself would
# shadow everything under it; do not.
#
# Note the deploy path does not use any of this. Ansible reaches hosts by
# instance ID through the Instance Connect Endpoint, from outside the VPC,
# where a private zone would not resolve anyway. This exists so the injector
# can resolve BASE_URL.
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "private" {
  name    = var.private_zone_name
  comment = "Private zone for ${local.name}; resolves only inside the VPC"

  vpc {
    vpc_id = aws_vpc.this.id
  }

  tags = { Name = local.name }
}

resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.private.zone_id
  name    = var.private_zone_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = false
  }
}
