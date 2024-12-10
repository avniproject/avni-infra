## Run Command to be used for Superset in Prod Env

```bash

docker run --name=avnisuperset_<version> --hostname=06e55a2490af --user=superset --mac-address=02:42:ac:11:00:02 --env=SUPERSET_SECRET_KEY=<key> --env=SUPERSET_DB_URL=<dbhostname> --env=SUPERSET_DB_NAME=<dbname> --env=SUPERSET_DB_USER=<dbuser> --env=SUPERSET_DB_PORT=5432 --env=SUPERSET_DB_PASSWORD=<dbpassword> --volume=/var/log/superset:/app/superset_home --network=bridge --workdir=/app -p 8088:8088 --restart=always --runtime=runc --detach=true 118388513628.dkr.ecr.ap-south-1.amazonaws.com/avniproject/reporting-superset:<version>
```