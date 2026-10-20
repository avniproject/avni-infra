variable "region" {
  description = "AWS region. Production is ap-south-1; I/O and instance pricing in the plan assume it."
  type        = string
  default     = "ap-south-1"
}

variable "injector_allowed_cidrs" {
  description = "Public source addresses permitted to reach the application port, as CIDRs. Set per run; see main.tf. Empty means unreachable."
  type        = list(string)
  default     = []
}

variable "app_instance_class" {
  description = <<-EOT
    avni-server host. The module default (m6g.large, 2 vCPU) is what every run
    through 19 Oct 2026 measured, and it is the size five independent runs found
    saturating on CPU.

    Exposed here for the vertical scale sweep, which tests the campaign's most
    repeated and least tested claim: that more vCPU is the relief. Sweep it with
    m6g.xlarge (4 vCPU) and m6g.2xlarge (8 vCPU), and put it back to m6g.large
    afterwards so later runs stay comparable with the recorded ones.

    Only the instance type moves. The heap stays pinned to production at
    -Xmx5120m in configure/group_vars/loadtest_vars.yml, so the extra RAM a
    larger instance brings is deliberately unused -- a different heap would make
    GC behaviour, and therefore the results, untransferable.
  EOT
  type        = string
  default     = "m6g.large"
}

variable "db_instance_class" {
  description = "RDS instance class. The module default (db.m6g.large) is fixed-performance on purpose; override only to park an idle environment, never for a measured run."
  type        = string
  default     = "db.m6g.large"
}
