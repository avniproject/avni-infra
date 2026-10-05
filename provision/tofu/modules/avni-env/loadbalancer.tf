# ---------------------------------------------------------------------------
# Edge: internet-facing ALB, fronted by a WAF
#
# This was internal, on the reasoning that the injector lives inside the VPC so
# there was no reason to expose it. F4 settled the other way — "a security
# group allowlist, not a private subnet" — because the customer has asked to
# run the injector from a local machine, and a local machine cannot reach an
# internal ALB.
#
# Internet-facing is a change of mechanism, not of strictness. B1 still
# requires the environment be unreachable from the internet at large; what
# enforces it is the ALB security group, whose only ingress is from
# injector_allowed_cidrs. Nothing under test gains a public IP: the app, ETL,
# database and loader stay in the private subnets with no inbound path.
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = local.name
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  # 300s, measured on the live prod-openchs-load-balancer. The 400s in
  # provision/server/elb.tf is stale — that belongs to the jasper ALB. Sync
  # requests are long enough that a shorter timeout converts slow responses
  # into errors, so this is a constraint to reproduce, not a detail.
  idle_timeout = var.alb_idle_timeout

  tags = { Name = local.name }
}

resource "aws_lb_target_group" "app" {
  name     = "${local.name}-app"
  port     = local.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  health_check {
    path                = "/ping"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = { Name = "${local.name}-app" }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.host["avni-server"].id
  port             = local.app_port
}

# HTTPS only, and no plain-HTTP fallback any more. Production terminates TLS at
# the ALB and termination costs something per request, so this is parity. The
# fallback existed because DNS validation was impossible for a private-zone
# name; the public delegated zone in dns.tf removes that obstacle and issues
# the certificate.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# WAF
#
# Production fronts its ALB with avni-prod-web-acl. A WAF inspects every
# request and adds latency production carries, so omitting it would make the
# rig faster than prod in a way no other parity check surfaces.
#
# The rate-based rule is the hazard. Production's limit is 550 per five-minute
# window per source IP — roughly 1.8 requests a second — which makes an
# un-allowlisted load test impossible rather than merely degraded, and the
# failure is quiet: blocked requests surface in the Gatling report as server
# errors or latency, not as a WAF decision.
#
# The injector is exempted with a scope-down statement rather than an allow
# rule. An allow rule short-circuits and would skip every subsequent rule,
# losing the per-request inspection cost that is the reason for having the WAF
# at all. A scope-down excludes the injector from *this* rule's counting while
# leaving all others in the evaluation path.
#
# Managed rule groups are empty by default — see waf_managed_rule_groups for
# why a guessed group is worse than none. That leaves a parity gap: production
# also runs Block_Known_Spammers, a php-rule and AWSManagedRulesAntiDDoSRuleSet,
# none of which is reproduced here. The gap belongs in the parity report rule by
# rule, because it is the part that most affects measured latency.
# ---------------------------------------------------------------------------

# Public addresses, not the VPC's private CIDRs. The ALB is internet-facing, so
# WAF aggregates on the client's real address: the office NAT address for a
# local run, the injector's elastic IP for an in-VPC one. Same list as the ALB
# security group ingress, by construction.
resource "aws_wafv2_ip_set" "injector" {
  name               = "${local.name}-injector"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = var.injector_allowed_cidrs

  tags = { Name = "${local.name}-injector" }
}

resource "aws_wafv2_web_acl" "this" {
  name  = local.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-rule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"

        scope_down_statement {
          not_statement {
            statement {
              ip_set_reference_statement {
                arn = aws_wafv2_ip_set.injector.arn
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "avni-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = var.waf_managed_rule_groups
    content {
      name     = rule.value
      priority = 10 + index(var.waf_managed_rule_groups, rule.value)

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = replace(rule.value, "AWSManagedRules", "")
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }

  tags = { Name = local.name }
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}
