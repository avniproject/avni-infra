.PHONY: install
UNAME := $(shell uname)
ifeq ($(UNAME),Linux)
	TERRAFORM_URL="https://releases.hashicorp.com/terraform/0.10.2/terraform_0.10.2_linux_amd64.zip"
endif
ifeq ($(UNAME),Darwin)
	TERRAFORM_URL="https://releases.hashicorp.com/terraform/0.10.2/terraform_0.10.2_darwin_amd64.zip"
endif
TERRAFORM_LOCATION:=/usr/local/bin/terraform

define create
	terraform get server;
	terraform apply -var 'environment=$(1)' server;
endef

define plan
	terraform plan -var 'environment=$(1)' server;
endef


define destroy
	terraform destroy -var 'environment=$(1)' server;
endef

unencrypt:
	@openssl aes-256-cbc -a -md md5 -in server/key/openchs-infra.pem.enc -d -out server/key/openchs-infra.pem -k ${ENCRYPTION_KEY_AWS}

install:
	rm -rf terraform terraform.zip
	curl -L $(TERRAFORM_URL) > terraform.zip
	unzip terraform.zip
	rm -rf terraform.zip
	-sudo mv terraform $(TERRAFORM_LOCATION)
	@openssl aes-256-cbc -a -md md5 -in server/key/openchs-infra.pem.enc -d -out server/key/openchs-infra.pem -k ${ENCRYPTION_KEY_AWS}
	terraform init -backend=true -backend-config="server/backend.config" server

staging-create:
	$(call create,staging)

staging-destroy:
	$(call destroy,staging)

staging-plan:
	$(call plan,staging)

demo-create:
	$(call create,demo)

demo-destroy:
	$(call destroy,staging)

demo-plan:
	$(call plan,demo)
