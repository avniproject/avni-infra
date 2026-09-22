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
