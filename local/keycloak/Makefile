keycloak-version=21.0.2

start-dev:
	cd keycloak-$(keycloak-version) && bin/kc.sh start-dev

start:
	keycloak-$(keycloak-version)/bin/kc.sh start-dev --hostname-strict=false --db-url-host localhost --db-username keycloak --db-password password --https-certificate-file=./domain.crt --https-certificate-key-file=./domain.key --log-level=WARN

import-starter-realm:
	sed 's|https://keycloak-staging.avniproject.org:8443|http://localhost:8080|g' On-premise-realm.json > starter-realm.json
	keycloak-$(keycloak-version)/bin/kc.sh import --file=starter-realm.json

open-https:
	make https://localhost:8443/

open-http:
	make http://localhost:8080/
