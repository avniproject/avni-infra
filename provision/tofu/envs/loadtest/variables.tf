variable "region" {
  description = "AWS region. Production is ap-south-1; I/O and instance pricing in the plan assume it."
  type        = string
  default     = "ap-south-1"
}
