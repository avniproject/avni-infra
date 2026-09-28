output "base_url" {
  description = "What the injector points BASE_URL at. Publicly resolvable, but reachable only from the enrolled addresses; identical from either injector position, which is what makes runs comparable."
  value       = "https://${var.zone_name}"
}

output "zone_name_servers" {
  description = "The zone's name servers, for the one-time NS delegation in the production account. The zone is NOT managed here — see scripts/bootstrap-dns-zone.sh — so these survive a destroy and the delegation never needs redoing."
  value       = data.aws_route53_zone.this.name_servers
}

output "injector_public_ip" {
  description = "The in-VPC injector's elastic IP. Enrol it as a /32 in injector_allowed_cidrs for runs driven from inside the VPC."
  value       = var.enable_injector ? aws_eip.injector[0].public_ip : null
}

output "injector_allowed_cidrs" {
  description = "Addresses currently permitted to reach the application port, echoed back so a run can record what was open. Empty means the environment is unreachable on that port."
  value       = var.injector_allowed_cidrs
}

output "instance_ids" {
  description = "Role to instance ID. The Ansible dynamic inventory discovers these from tags rather than reading this output, but a human debugging the tunnel wants them."
  value       = { for role, host in aws_instance.host : role => host.id }
}

output "db_endpoint" {
  description = "Primary database endpoint."
  value       = aws_db_instance.this.endpoint
}

output "db_replica_endpoint" {
  description = "Read replica endpoint, when one exists."
  value       = var.enable_read_replica ? aws_db_instance.replica[0].endpoint : null
}

output "db_master_secret_arn" {
  description = "Secrets Manager ARN holding the generated master password. The password itself never enters OpenTofu state."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "bucket" {
  description = "Environment bucket. artefacts/ for run output, deployables/ for jars."
  value       = aws_s3_bucket.env.id
}

output "instance_connect_endpoint_id" {
  description = "Needed by the Ansible ProxyCommand when addressing hosts by instance ID."
  value       = aws_ec2_instance_connect_endpoint.this.id
}

output "web_acl_arn" {
  description = "WAF web ACL. Check each rule's own CloudWatch metric after the first run, not the ACL's counters: with the injector scope-down the rate rule cannot fire, so BlockedRequests reads clean while a managed group blocks."
  value       = aws_wafv2_web_acl.this.arn
}

output "cognito_user_pool_id" {
  description = "For the harness's auth-cost measurement (B2), which runs here and nowhere else. Feed into loadtest_cognito_user_pool_id in Ansible."
  value       = var.enable_cognito ? aws_cognito_user_pool.this[0].id : null
}

output "cognito_client_id" {
  description = "App client for B2's AUTH_MODE=cognito run. Feed into loadtest_cognito_client_id in Ansible."
  value       = var.enable_cognito ? aws_cognito_user_pool_client.this[0].id : null
}
