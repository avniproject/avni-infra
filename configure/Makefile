check-web-zip-path:
ifndef web_zip_path
	$(error web_zip_path is undefined)
endif

check-app-zip-path:
ifndef app_zip_path
	$(error app_zip_path is undefined)
endif

check-vault-pwd-file:
ifndef VAULT_PASSWORD_FILE
	$(error VAULT_PASSWORD_FILE is undefined)
endif

check-keycloak-setup-pwd:
ifndef keycloak_db_password
	$(error keycloak_db_password is undefined)
endif
ifndef keycloak_admin_pwd
	$(error keycloak_admin_pwd is undefined)
endif
ifndef keycloak_admin_api_secret
	$(error keycloak_admin_api_secret is undefined)
endif

check-minio-setup-pwd:
ifndef minio_root_user
	$(error minio_root_user is undefined)
endif
ifndef minio_root_password
	$(error minio_root_password is undefined)
endif
ifndef minio_upload_user
	$(error minio_upload_user is undefined)
endif
ifndef minio_upload_password
	$(error minio_upload_password is undefined)
endif

avni-local: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook vagrant_avni_servers.yml -i inventory/vagrant_local  --vault-password-file ${VAULT_PASSWORD_FILE}

int-local: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook vagrant_integration_servers.yml -i inventory/vagrant_local  --vault-password-file ${VAULT_PASSWORD_FILE}

keycloak-local:
	ansible-playbook site.yml --tags=keycloak -i inventory/vagrant_local --vault-password-file ${VAULT_PASSWORD_FILE}

keycloak-staging: check-keycloak-setup-pwd
	KEYCLOAK_DB_PASSWORD=$(keycloak_db_password) KEYCLOAK_ADMIN_PWD=$(keycloak_admin_pwd) KEYCLOAK_ADMIN_API_SECRET=$(keycloak_admin_api_secret) ansible-playbook staging_keycloak_servers.yml --tags=keycloak -i inventory/staging

keycloak-onpremise: check-keycloak-setup-pwd
	KEYCLOAK_DB_PASSWORD=$(keycloak_db_password) KEYCLOAK_ADMIN_PWD=$(keycloak_admin_pwd) KEYCLOAK_ADMIN_API_SECRET=$(keycloak_admin_api_secret) ansible-playbook onpremise_keycloak_servers.yml --tags=keycloak -i inventory/onpremise

minio-staging: check-minio-setup-pwd
	MINIO_ROOT_USER=$(minio_root_user) MINIO_ROOT_PASSWORD=$(minio_root_password) MINIO_UPLOAD_USER=$(minio_upload_user) MINIO_UPLOAD_PASSWORD=$(minio_upload_password) ansible-playbook staging_minio_servers.yml -i inventory/staging

minio-onpremise: check-minio-setup-pwd
	MINIO_ROOT_USER=$(minio_root_user) MINIO_ROOT_PASSWORD=$(minio_root_password) MINIO_UPLOAD_USER=$(minio_upload_user) MINIO_UPLOAD_PASSWORD=$(minio_upload_password) ansible-playbook onpremise_minio_servers.yml -i inventory/onpremise

avni-staging: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook staging_avni_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"application_user":"avni-server-user"}'

avni-prerelease: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook prerelease_avni_servers.yml -i inventory/prerelease  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"application_user":"avni-server-user"}'

avni-prod: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook prod_avni_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"application_user":"avni-server-user"}'

avni-onpremise: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook onpremise_avni_servers.yml -i inventory/onpremise  --vault-password-file ${VAULT_PASSWORD_FILE}

rwb-staging: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook rwb_staging_avni_servers.yml -i inventory/rwb_staging  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"application_user":"avni-server-user"}'

rwb-prod: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook rwb_prod_avni_servers.yml -i inventory/rwb_prod  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"application_user":"avni-server-user"}'

configure-reverse-proxy:
	ansible-playbook reverse_proxy_server.yml -i inventory/onpremise

int-staging: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook staging_integration_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE}

int-prerelease: check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook prerelease_integration_servers.yml -i inventory/prerelease  --vault-password-file ${VAULT_PASSWORD_FILE}

int-prod: check-web-zip-path check-app-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook prod_integration_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}

rules-server-onpremise: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=rules-server.tgz ansible-playbook onpremise_rules_server.yml -i inventory/onpremise  --vault-password-file ${VAULT_PASSWORD_FILE}

rules-server-staging: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=rules-server.tgz ansible-playbook staging_rules_server.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE}

rules-server-prerelease: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=rules-server.tgz ansible-playbook prerelease_rules_server.yml -i inventory/prerelease  --vault-password-file ${VAULT_PASSWORD_FILE}

rules-server-prod: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=rules-server.tgz ansible-playbook prod_rules_server.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}

rules-server-rwb-staging: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=rules-server.tgz ansible-playbook rwb_staging_rules_server.yml -i inventory/rwb_staging  --vault-password-file ${VAULT_PASSWORD_FILE}

rules-server-rwb-prod: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=rules-server.tgz ansible-playbook rwb_prod_rules_server.yml -i inventory/rwb_prod  --vault-password-file ${VAULT_PASSWORD_FILE}

decrypt: check-vault-pwd-file
	cp group_vars/prod-secret-vars.yml.enc group_vars/prod-secret-vars.yml
	cp group_vars/staging-secret-vars.yml.enc group_vars/staging-secret-vars.yml
	cp group_vars/prerelease-secret-vars.yml.enc group_vars/prerelease-secret-vars.yml
	cp group_vars/vagrant-secret-vars.yml.enc group_vars/vagrant-secret-vars.yml
	cp group_vars/onpremise-secret-vars.yml.enc group_vars/onpremise-secret-vars.yml
	cp group_vars/rwb_staging-secret-vars.yml.enc group_vars/rwb_staging-secret-vars.yml
	ansible-vault decrypt group_vars/prod-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault decrypt group_vars/staging-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault decrypt group_vars/prerelease-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault decrypt group_vars/vagrant-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault decrypt group_vars/onpremise-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault decrypt group_vars/rwb_staging-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}

decrypt_env: check-vault-pwd-file
	cp group_vars/$(env)-secret-vars.yml.enc group_vars/$(env)-secret-vars.yml
	ansible-vault decrypt group_vars/$(env)-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}

encrypt: check-vault-pwd-file
	ansible-vault encrypt group_vars/prod-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault encrypt group_vars/staging-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault encrypt group_vars/prerelease-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault encrypt group_vars/vagrant-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault encrypt group_vars/onpremise-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	ansible-vault encrypt group_vars/rwb_staging-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	cp group_vars/prod-secret-vars.yml group_vars/prod-secret-vars.yml.enc
	cp group_vars/staging-secret-vars.yml group_vars/staging-secret-vars.yml.enc
	cp group_vars/prerelease-secret-vars.yml group_vars/prerelease-secret-vars.yml.enc
	cp group_vars/vagrant-secret-vars.yml group_vars/vagrant-secret-vars.yml.enc
	cp group_vars/onpremise-secret-vars.yml group_vars/onpremise-secret-vars.yml.enc
	cp group_vars/rwb_staging-secret-vars.yml group_vars/rwb_staging-secret-vars.yml.enc

encrypt_env: check-vault-pwd-file
	ansible-vault encrypt group_vars/$(env)-secret-vars.yml --vault-password-file ${VAULT_PASSWORD_FILE}
	cp group_vars/$(env)-secret-vars.yml group_vars/$(env)-secret-vars.yml.enc

etl-onpremise: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook onpremise_etl_servers.yml -i inventory/onpremise  --vault-password-file ${VAULT_PASSWORD_FILE}

etl-staging: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook staging_etl_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE}

etl-prerelease: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook prerelease_etl_servers.yml -i inventory/prerelease  --vault-password-file ${VAULT_PASSWORD_FILE}

etl-prod: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook prod_etl_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}

etl-rwb-staging: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook rwb_staging_etl_servers.yml -i inventory/rwb_staging  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"java_apt_package":"openjdk-17-jdk"}'

etl-rwb-prod: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook rwb_prod_etl_servers.yml -i inventory/rwb_prod  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"java_apt_package":"openjdk-17-jdk"}'

metabase-onpremise:
	ansible-playbook onpremise_metabase_servers.yml -i inventory/onpremise  --vault-password-file ${VAULT_PASSWORD_FILE}

jasper-rwb-staging: check-vault-pwd-file
	ansible-playbook rwb_jasperserver_servers.yml -i inventory/rwb_staging --vault-password-file ${VAULT_PASSWORD_FILE}

deploy-etl-staging: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook deploy_app_to_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"deploy_app_name":"etl","deploy_app_hosts":"etlservers","deploy_app_remote_user":"avni-etl-user","deploy_app_env":"staging","deploy_app_role":"etl_appserver","deploy_app_env_vars_file":"group_vars/staging_vars.yml","deploy_app_env_secret_vars_file":"group_vars/staging-secret-vars.yml.enc"}'

deploy-etl-prerelease: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook deploy_app_to_servers.yml -i inventory/prerelease  --vault-password-file ${VAULT_PASSWORD_FILE} \
	--extra-vars '{"deploy_app_name":"etl","deploy_app_hosts":"etlservers","deploy_app_remote_user":"avni-etl-user","deploy_app_env":"prerelease","deploy_app_role":"etl_appserver","deploy_app_env_vars_file":"group_vars/prerelease_vars.yml","deploy_app_env_secret_vars_file":"group_vars/prerelease-secret-vars.yml.enc"}'

deploy-etl-prod: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=etl-1.0.0-SNAPSHOT.jar ansible-playbook deploy_app_to_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"etl","deploy_app_hosts":"etlservers","deploy_app_remote_user":"avni-etl-user","deploy_app_env":"prod","deploy_app_role":"etl_appserver","deploy_app_env_vars_file":"group_vars/prod_vars.yml","deploy_app_env_secret_vars_file":"group_vars/prod-secret-vars.yml.enc"}'

deploy-int-server-staging: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook deploy_app_to_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"int","deploy_app_hosts":"webservers","deploy_app_remote_user":"avni-int-user","deploy_app_env":"staging","deploy_app_role":"int_appserver","deploy_app_env_vars_file":"group_vars/staging_vars.yml","deploy_app_env_secret_vars_file":"group_vars/staging-secret-vars.yml.enc"}'

deploy-int-server-prod: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook deploy_app_to_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"int","deploy_app_hosts":"webservers","deploy_app_remote_user":"avni-int-user","deploy_app_env":"prod","deploy_app_role":"int_appserver","deploy_app_env_vars_file":"group_vars/prod_vars.yml","deploy_app_env_secret_vars_file":"group_vars/prod-secret-vars.yml.enc"}'

deploy-int-webapp-staging: check-web-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz ansible-playbook deploy_app_to_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"int","deploy_app_hosts":"webservers","deploy_app_remote_user":"avni-int-user","deploy_app_env":"staging","deploy_app_role":"int_web","deploy_app_env_vars_file":"group_vars/staging_vars.yml","deploy_app_env_secret_vars_file":"group_vars/staging-secret-vars.yml.enc"}'

deploy-int-webapp-prod: check-web-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz ansible-playbook deploy_app_to_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"int","deploy_app_hosts":"webservers","deploy_app_remote_user":"avni-int-user","deploy_app_env":"prod","deploy_app_role":"int_web","deploy_app_env_vars_file":"group_vars/prod_vars.yml","deploy_app_env_secret_vars_file":"group_vars/prod-secret-vars.yml.enc"}'

deploy-avni-server-staging: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook deploy_app_to_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"avni","deploy_app_hosts":"avniservers","deploy_app_remote_user":"avni-server-user","deploy_app_env":"staging","deploy_app_role":"avni_appserver","deploy_app_env_vars_file":"group_vars/staging_vars.yml","deploy_app_env_secret_vars_file":"group_vars/staging-secret-vars.yml.enc"}'

deploy-avni-server-prod: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook deploy_app_to_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"avni","deploy_app_hosts":"avniservers","deploy_app_remote_user":"avni-server-user","deploy_app_env":"prod","deploy_app_role":"avni_appserver","deploy_app_env_vars_file":"group_vars/prod_vars.yml","deploy_app_env_secret_vars_file":"group_vars/prod-secret-vars.yml.enc"}'

deploy-avni-server-prerelease: check-app-zip-path check-vault-pwd-file
	APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=avni-server-0.0.1-SNAPSHOT.jar ansible-playbook deploy_app_to_servers.yml -i inventory/prerelease  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"avni","deploy_app_hosts":"avniservers","deploy_app_remote_user":"avni-server-user","deploy_app_env":"prerelease","deploy_app_role":"avni_appserver","deploy_app_env_vars_file":"group_vars/prerelease_vars.yml","deploy_app_env_secret_vars_file":"group_vars/prerelease-secret-vars.yml.enc"}'

deploy-avni-webapp-staging: check-web-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz ansible-playbook deploy_app_to_servers.yml -i inventory/staging  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"avni","deploy_app_hosts":"avniservers","deploy_app_remote_user":"avni-server-user","deploy_app_env":"staging","deploy_app_role":"avni_web","deploy_app_env_vars_file":"group_vars/staging_vars.yml","deploy_app_env_secret_vars_file":"group_vars/staging-secret-vars.yml.enc"}'

deploy-avni-webapp-prod: check-web-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz ansible-playbook deploy_app_to_servers.yml -i inventory/prod  --vault-password-file ${VAULT_PASSWORD_FILE}  \
     --extra-vars '{"deploy_app_name":"avni","deploy_app_hosts":"avniservers","deploy_app_remote_user":"avni-server-user","deploy_app_env":"prod","deploy_app_role":"avni_web","deploy_app_env_vars_file":"group_vars/prod_vars.yml","deploy_app_env_secret_vars_file":"group_vars/prod-secret-vars.yml.enc"}'

deploy-avni-webapp-prerelease: check-web-zip-path check-vault-pwd-file
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-webapp.tgz ansible-playbook deploy_app_to_servers.yml -i inventory/prerelease  --vault-password-file ${VAULT_PASSWORD_FILE}  \
	--extra-vars '{"deploy_app_name":"avni","deploy_app_hosts":"avniservers","deploy_app_remote_user":"avni-server-user","deploy_app_env":"prerelease","deploy_app_role":"avni_web","deploy_app_env_vars_file":"group_vars/prerelease_vars.yml","deploy_app_env_secret_vars_file":"group_vars/prerelease-secret-vars.yml.enc"}'
