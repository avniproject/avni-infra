## Run Command to be used for Metabase in Prod Env

```bash

docker run --name=metabase --hostname=ec44837f08b2 --mac-address=02:42:ac:11:00:02 --env=MB_DB_PASS=<dbpassword> --env=MB_PASSWORD_LENGTH=12 --env=MB_DB_HOST=<dbhostname> --env=JAVA_OPTS=-Xmx2560m --env=JAVA_TIMEZONE=Asia/Kolkata --env=MB_DB_DBNAME=<database> --env=MB_DB_USER=<dbusername> --env=MB_JETTY_PORT=3000 --env=MB_PASSWORD_COMPLEXITY=strong --env=MB_DB_TYPE=postgres --env=MB_DB_PORT=5432 -p 3000:3000 --restart=always --log-opt max-size=10m --log-opt max-file=10 --runtime=runc --detach=true metabase/metabase:v0.50.31.4
```