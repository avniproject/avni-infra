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
	terraform apply -var 'environment=$(1)' $(2);
endef

define plan
	terraform plan -var 'environment=$(1)' $(2);
endef


define destroy
	terraform destroy -var 'environment=$(1)' $(2);
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
	terraform init -backend=true -backend-config="reporting/backend.config" reporting

staging-create:
	$(call create,staging,server)

staging-destroy:
	$(call destroy,staging,server)

staging-plan:
	$(call plan,staging,server)

demo-create:
	$(call create,demo,server)

demo-destroy:
	$(call destroy,staging,server)

demo-plan:
	$(call plan,demo)

reporting-create:
	$(call create,staging,reporting)

reporting-destroy:
	$(call destroy,staging,reporting)

reporting-plan:
	$(call plan,staging,reporting)
