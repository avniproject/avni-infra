# ---------------------------------------------------------------------------
# Identity and networking
# ---------------------------------------------------------------------------

variable "environment" {
  description = "Environment name. Used in resource names and in the Environment tag the Ansible dynamic inventory filters on."
  type        = string
  default     = "loadtest"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Does not need to avoid production's ranges — this environment is in its own account and peers with nothing."
  type        = string
  default     = "10.60.0.0/16"
}

variable "private_zone_name" {
  description = <<-EOT
    Route53 private hosted zone. Needs no registration or delegation: a private
    zone resolves only inside associated VPCs and never touches public DNS.
    Route53 matches most-specific-first, so a zone for loadtest.avniproject.org
    shadows only names at or below it — app.avniproject.org still resolves
    publicly from inside the VPC. Do not use avniproject.org itself.
  EOT
  type        = string
  default     = "loadtest.avniproject.org"
}

# ---------------------------------------------------------------------------
# Compute
#
# Fixed-performance Graviton throughout. Production runs burstable (t3.large,
# db.t4g.large, t3.small) in unlimited mode, so credit exhaustion does not
# throttle it — but a load test is precisely the sustained-CPU workload that
# maximises surplus-credit charges, and a fixed instance removes a variable
# from every run. See the plan, section 5.
# ---------------------------------------------------------------------------

variable "app_instance_class" {
  description = "avni-server host. m6g.large is 2 vCPU / 8 GiB, matching production's t3.large shape at 44% less per hour."
  type        = string
  default     = "m6g.large"
}

variable "enable_etl" {
  description = <<-EOT
    Create the avni-etl host. Defaults ON: the harness requires
    sync-with-concurrent-ETL as a scenario, because ETL runs a 90-minute Quartz
    cycle competing with sync for the same fixed IOPS. The variable exists to
    toggle between runs, not to omit the host.
  EOT
  type        = bool
  default     = true
}

variable "etl_instance_class" {
  description = "avni-etl host. m6g.medium is 1 vCPU / 4 GiB — double production's t3.small memory, which runs a ~1.6 GiB JVM on a 2 GiB box."
  type        = string
  default     = "m6g.medium"
}

variable "enable_injector" {
  description = "Create the Gatling injector inside the VPC. On-demand only — a Spot reclaim mid-run ends the run, and the saving is cents."
  type        = bool
  default     = true
}

variable "injector_instance_class" {
  description = "Load injector. Sized for CPU and network rather than memory."
  type        = string
  default     = "m6g.xlarge"
}

variable "enable_loader" {
  description = "Create the dataset-loader host. Created for the bulk load and destroyed after; not part of steady state."
  type        = bool
  default     = false
}

variable "loader_instance_class" {
  description = "Dataset loader. Runs the generator and its COPY into Postgres."
  type        = string
  default     = "m6g.large"
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

variable "db_instance_class" {
  description = "db.m6g.large keeps production's 2 vCPU / 8 GiB and its Graviton architecture, removing only burstability."
  type        = string
  default     = "db.m6g.large"
}

variable "db_engine_version" {
  description = "Match the production primary. Note the estate has drifted — replica, prerelease and staging are on 16.13 — so this is a moving target."
  type        = string
  default     = "16.8"
}

variable "db_allocated_storage" {
  description = <<-EOT
    Allocated GiB. MUST stay below 400: RDS gp3 for PostgreSQL is a flat
    3000 IOPS / 125 MiB/s across the whole 20-399 GiB band, and at 400 GiB it
    restripes to 12000 / 500 — four times production's storage performance,
    which would mask the very bottleneck this environment exists to find.
    Sized on capacity, not on matching production's 300 GiB: ~70 GB dataset,
    plus a template copy if that reset mechanism wins, plus up to ~62 GB of
    ETL schemas generated during ETL-concurrent runs.
  EOT
  type        = number
  default     = 250

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage < 400
    error_message = "Must be 20-399 GiB. At 400+ the volume restripes to 12000 IOPS / 500 MiB/s and I/O parity with production is lost."
  }
}

variable "db_multi_az" {
  description = "Production is single-AZ, so this is too. Multi-AZ would add synchronous-standby commit latency production does not have."
  type        = bool
  default     = false
}

variable "enable_read_replica" {
  description = "Production has one. Note it is a db.t4g.medium — half the primary's memory — and runs its own parameter group."
  type        = bool
  default     = false
}

variable "replica_instance_class" {
  description = "Read replica. Production's is smaller than its primary; matching that shape matters for read-path fidelity."
  type        = string
  default     = "db.m6g.medium"
}

variable "db_max_connections" {
  description = "RDS parameter group max_connections. Production peaks at 122-130, above the ~100 Tomcat JDBC default that caused the July pool exhaustion."
  type        = number
  default     = 200
}

variable "db_autovacuum" {
  description = "Leave autovacuum on for realism — production has it on, and an autovacuum storm mid-run is a genuine production failure mode. Record it as a source of run-to-run variance."
  type        = bool
  default     = true
}

variable "restore_from_snapshot" {
  description = "Rebuild from the baseline snapshot rather than an empty instance. The baseline is created and guarded by the harness, and is NOT managed by this module."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Edge and storage
# ---------------------------------------------------------------------------

variable "alb_idle_timeout" {
  description = "300s, measured on the live prod-openchs-load-balancer. The 400s in provision/server/elb.tf is stale — that is the jasper ALB. Sync requests are long, so this is a real constraint."
  type        = number
  default     = 300
}

variable "waf_rate_limit" {
  description = <<-EOT
    Production's rate-based rule is 550 per 5-minute window per source IP —
    roughly 1.8 req/s, which makes an un-allowlisted load test impossible rather
    than merely degraded. Reproduce the limit, and allowlist the injector's
    subnet ahead of it so every other rule stays in the evaluation path.
  EOT
  type        = number
  default     = 550
}

variable "enable_media_bucket" {
  description = "Off by default. Presigning is local and nothing validates the bucket's existence, so a real bucket is probably unnecessary; the requirement is a configured bucketName and a populated mediaDirectory."
  type        = bool
  default     = false
}

variable "enable_cognito" {
  description = <<-EOT
    Create a Cognito pool. Defaults OFF: B1 (AVNI_IDP_TYPE=none) is decided and
    B2 — the auth-cost measurement that was the only reason to stand Cognito up
    — is deferred, because it needs a working Cognito path and the simulation
    strips Cognito entirely. The environment therefore starts closed rather than
    opening and later closing. Kept as a variable so an un-deferred B2 is one
    flag away.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch retention. Request logging is high volume — AuthenticationFilter logs twice per request including the query string."
  type        = number
  default     = 14
}

variable "monthly_budget_usd" {
  description = "Budget alarm threshold. Storage dominates: ~250 GiB of gp3 is about USD 33/month whether anything runs or not, against ~USD 6 for the database at 26 hours."
  type        = number
  default     = 150
}

variable "retain_on_destroy" {
  description = "Keep the database's final snapshot on destroy. The baseline snapshot itself lives outside this module and must survive regardless."
  type        = bool
  default     = true
}

variable "ssh_public_key" {
  description = "Public key for the instances. Access is normally via EC2 Instance Connect through the endpoint; this is the break-glass path."
  type        = string
  default     = null
}

variable "ubuntu_release" {
  description = <<-EOT
    Ubuntu release for the hosts, as it appears in Canonical's SSM parameter
    path. 22.04 is conservative — the Ansible roles predate 24.04 and the
    `docker` role still defaults its apt release to focal. Note the Makefile
    passes openjdk-21-jdk explicitly, which 22.04 carries.
  EOT
  type        = string
  default     = "22.04"
}

variable "acm_certificate_arn" {
  description = "ACM certificate for the ALB's HTTPS listener. Null gives a plain HTTP listener, which is a deviation from production's TLS termination and must be recorded in the parity report."
  type        = string
  default     = null
}

variable "waf_managed_rule_groups" {
  description = <<-EOT
    AWS managed rule groups to evaluate alongside the rate-based rule.
    Production also runs custom rules — Block_Known_Spammers and a php-rule —
    whose full statements were not captured by discovery, only their names.
    Transcribe them from the production web ACL for closer parity, and note
    AWSManagedRulesAntiDDoSRuleSet carries a standing monthly charge.
  EOT
  type        = list(string)
  default     = ["AWSManagedRulesCommonRuleSet"]
}
