check-zip-path:
ifndef web_zip_path
	$(error web_zip_path is undefined)
endif
ifndef app_zip_path
	$(error app_zip_path is undefined)
endif

check-vault-pwd-file:
ifndef VAULT_PASSWORD_FILE
	$(error VAULT_PASSWORD_FILE is undefined)
endif

int-local: check-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook vagrant_integration_servers.yml -i inventory/vagrant_local  --vault-password-file ${VAULT_PASSWORD_FILE}

keycloak-local:
	ansible-playbook site.yml --tags=keycloak -i inventory/vagrant_local --vault-password-file ${VAULT_PASSWORD_FILE}

int-staging: check-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook staging_integration_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE}

int-prod: check-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook prod_integration_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}

decrypt: check-vault-pwd-file
	cp group_vars/prod-secret-vars.yml.enc group_vars/prod-secret-vars.yml
	cp group_vars/staging-secret-vars.yml.enc group_vars/staging-secret-vars.yml
	ansible-vault decrypt group_vars/prod-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault decrypt group_vars/staging-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}

encrypt: check-vault-pwd-file
	ansible-vault encrypt group_vars/prod-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault encrypt group_vars/staging-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	cp group_vars/prod-secret-vars.yml group_vars/prod-secret-vars.yml.enc
	cp group_vars/staging-secret-vars.yml group_vars/staging-secret-vars.yml.enc