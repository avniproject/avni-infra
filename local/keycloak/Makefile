start:
	cd keycloak-21.0.1 && bin/kc.sh start-dev

import-starter-realm:
	-rm starter-realm.json
	sed 's|https://keycloak-staging.avniproject.org:8443|http://localhost:8080|g' ../../integration/configure/roles/keycloak/files/starter-realm.json > starter-realm.json
	keycloak-21.0.1/bin/kc.sh import --file=starter-realm.json
