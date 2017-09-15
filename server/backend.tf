terraform {
  backend "s3" {
    bucket = "openchs"
    key = "terraform-state/backend/terraform.tfstate"
    encrypt = true
  }
}