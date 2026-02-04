.PHONY: help deploy-prod deploy-staging encrypt decrypt setup-secrets

check-vault-pwd-file:
ifndef VAULT_PASSWORD_FILE
	$(error VAULT_PASSWORD_FILE is undefined)
endif

encrypt: check-vault-pwd-file
	@ansible-vault encrypt group_vars/production-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	@ansible-vault encrypt group_vars/staging-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}

decrypt: check-vault-pwd-file
	@ansible-vault decrypt group_vars/production-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	@ansible-vault decrypt group_vars/staging-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}

deploy-prod: check-vault-pwd-file
	@ansible-playbook -i inventory/production playbooks/production.yml --vault-password-file ${VAULT_PASSWORD_FILE}

deploy-staging: check-vault-pwd-file
	@ansible-playbook -i inventory/staging playbooks/staging.yml --vault-password-file ${VAULT_PASSWORD_FILE}