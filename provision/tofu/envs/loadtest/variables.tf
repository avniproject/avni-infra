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

variable "injector_instance_class" {
  description = <<-EOT
    Gatling injector. m6g.xlarge (4 vCPU) drove every run through row 26 of
    avni-perf's execution plan and never passed 13% mean CPU -- 10,000 users an
    hour at ~230 rps on row 26 held at 11-13%, so the campaign ends with it on
    m6g.large (2 vCPU), which is the default from 23 Oct 2026. An injector short
    of CPU reports the server slower than it is (F7); check its CPU in the run
    log before blaming the server if a run ever injects faster than that.

    Exposed here for the same reason as app_instance_class: a resize that does
    not go through state is undone by the next apply, and nothing records which
    size a run used.
  EOT
  type        = string
  default     = "m6g.large"
}

variable "db_iops" {
  description = "gp3 provisioned IOPS; null is the 3,000 baseline. A dataset load is IO-bound (23 Oct 2026); raise it for the load and put it back."
  type        = number
  default     = null
}

variable "db_storage_throughput" {
  description = "gp3 provisioned throughput in MB/s; null is the 125 baseline."
  type        = number
  default     = null
}

variable "db_instance_class" {
  description = "RDS instance class. The module default (db.m6g.large) is fixed-performance on purpose; override only to park an idle environment, never for a measured run."
  type        = string
  default     = "db.m6g.large"
}
