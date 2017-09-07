.PHONY: install
UNAME := $(shell uname)
ifeq ($(UNAME),Linux)
	TERRAFORM_URL="https://releases.hashicorp.com/terraform/0.10.2/terraform_0.10.2_linux_amd64.zip"
endif
ifeq ($(UNAME),Darwin)
	TERRAFORM_URL="https://releases.hashicorp.com/terraform/0.10.2/terraform_0.10.2_darwin_amd64.zip"
endif

install:
	rm -rf terraform terraform.zip
	curl -L $(TERRAFORM_URL) > terraform.zip
	unzip terraform.zip
	rm -rf terraform.zip
	mv terraform /usr/local/bin/terraform
	terraform init -backend=true -backend-config="ci/backend.config" ci

create-ci:
	@echo "Creating CI"
	terraform get ci
	terraform apply ci
	@echo "CI Up to Date"