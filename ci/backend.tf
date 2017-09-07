terraform {
  backend "s3" {
    bucket = "openchs"
    key = "terraform-state/ci/terraform.tfstate"
    encrypt = true
  }
}