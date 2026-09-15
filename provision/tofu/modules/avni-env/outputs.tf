output "base_url" {
  description = "What the injector points BASE_URL at. Resolves only inside the VPC."
  value       = "http${var.acm_certificate_arn == null ? "" : "s"}://${var.private_zone_name}"
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
  description = "WAF web ACL. Check BlockedRequests and CountedRequests after the first run rather than assuming the injector is passing."
  value       = aws_wafv2_web_acl.this.arn
}

output "cognito_user_pool_id" {
  description = "Present only while the environment is open, for the harness's auth-cost measurement."
  value       = var.enable_cognito ? aws_cognito_user_pool.this[0].id : null
}
