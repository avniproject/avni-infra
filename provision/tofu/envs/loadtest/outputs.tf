# ---------------------------------------------------------------------------
# Root outputs
#
# The module defines these; a root has to re-export them or `tofu output`
# reports "No outputs found" and the values are reachable only by digging
# through state. That is not a cosmetic gap: Ansible's group_vars/loadtest_vars.yml
# reads loadtest_db_host and loadtest_db_secret_name from here, and the
# injector needs base_url.
# ---------------------------------------------------------------------------

output "base_url" {
  description = "What the injector points BASE_URL at."
  value       = module.avni_env.base_url
}

output "zone_name_servers" {
  description = "NS record set to add for this zone in avniproject.org, which lives in the production account."
  value       = module.avni_env.zone_name_servers
}

output "instance_ids" {
  description = "Role to instance ID. Ansible discovers hosts by tag rather than reading this, but a human debugging the tunnel wants it."
  value       = module.avni_env.instance_ids
}

output "instance_connect_endpoint_id" {
  description = "Needed by the Ansible ProxyCommand when addressing hosts by instance ID."
  value       = module.avni_env.instance_connect_endpoint_id
}

output "injector_public_ip" {
  description = "The in-VPC injector's elastic IP. Enrol it as a /32 in injector_allowed_cidrs for runs driven from inside the VPC."
  value       = module.avni_env.injector_public_ip
}

output "injector_allowed_cidrs" {
  description = "Addresses currently able to reach the application port. Empty means unreachable."
  value       = module.avni_env.injector_allowed_cidrs
}

# Host part feeds loadtest_db_host; the endpoint carries :5432 which the
# Ansible var does not want.
output "db_endpoint" {
  description = "Primary database endpoint, host:port."
  value       = module.avni_env.db_endpoint
}

output "db_master_secret_arn" {
  description = "Secrets Manager ARN holding the generated master password. The password itself never enters OpenTofu state; Ansible reads it at run time."
  value       = module.avni_env.db_master_secret_arn
}

output "bucket" {
  description = "Environment bucket. artefacts/ for run output, deployables/ for jars."
  value       = module.avni_env.bucket
}

output "web_acl_arn" {
  description = "WAF web ACL. Check each rule's own metric after a run, not the ACL's counters."
  value       = module.avni_env.web_acl_arn
}
