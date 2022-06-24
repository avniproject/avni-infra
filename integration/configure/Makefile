int-local:
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook vagrant_integration_servers.yml -i inventory/vagrant_local

keycloak-local:
	ansible-playbook keyclock_server.yml -i inventory/vagrant_local

int-staging:
	WEBAPP_ZIP_PATH=$(web_zip_path) WEBAPP_ZIP_FILE_NAME=avni-int-admin-app.tgz APPLICATION_ZIP_PATH=$(app_zip_path) APPLICATION_ZIP_FILE_NAME=integrator-0.0.2-SNAPSHOT.jar ansible-playbook onpremise_integration_servers.yml -i inventory/staging
