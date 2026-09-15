# ---------------------------------------------------------------------------
# Edge: internal ALB, fronted by a WAF
#
# Internal, not internet-facing. The injector lives inside the VPC, so there is
# no reason to expose this — and B1 requires the environment be unreachable
# from outside once AVNI_IDP_TYPE=none is on.
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = local.name
  internal           = true
  load_balancer_type = "application"
  subnets            = aws_subnet.private[*].id
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

# TLS is a recorded deviation when absent. Production terminates HTTPS at the
# ALB, and termination has a measurable per-request cost — but a certificate
# for a private-zone name needs either DNS validation records added to the
# public avniproject.org zone (which lives in the production account) or an
# imported certificate. Pass an ARN to get parity; leave it null and the
# listener is plain HTTP, which the parity report must then record.
resource "aws_lb_listener" "https" {
  count = var.acm_certificate_arn == null ? 0 : 1

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http" {
  count = var.acm_certificate_arn == null ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTP"

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
# ---------------------------------------------------------------------------

resource "aws_wafv2_ip_set" "injector" {
  name               = "${local.name}-injector"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = local.private_cidrs

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
