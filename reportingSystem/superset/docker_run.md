## Run Command to be used for Superset in Prod Env

```bash

docker run --name=avnisuperset_<version> --hostname=06e55a2490af --user=superset --env=SUPERSET_SECRET_KEY=<key> --env=SUPERSET_DB_URL=<dbhostname> --env=SUPERSET_DB_NAME=<dbname> --env=SUPERSET_DB_USER=<dbuser> --env=SUPERSET_DB_PORT=5432 --env=SUPERSET_DB_PASSWORD=<dbpassword> --env=SERVER_WORKER_AMOUNT=2 --env=GUNICORN_TIMEOUT=120 --volume=/var/log/superset:/app/superset_home --network=bridge --workdir=/app -p 127.0.0.1:8088:8088 --restart=always --runtime=runc --log-opt max-size=100m --log-opt max-file=10 --memory=2500m --detach=true 118388513628.dkr.ecr.ap-south-1.amazonaws.com/avniproject/reporting-superset:6.0.0-prod
```

- nginx on the host (80 and 443) is the only way in. It proxies to `127.0.0.1:8088`, so the port is published on loopback only and the security group must not open 8088.
- The image runs gunicorn. Use a `-prod` tag; the plain `6.0.0` tag still starts the development server with its debugger.
- `SUPERSET_SECRET_KEY` must stay the same across redeploys, or the database passwords Superset stores cannot be decrypted.
- Build `-prod` tags with `docker image build --build-arg TAG=<superset version> -t avniproject/reporting-superset:<superset version>-prod .`, not `make build-image`, whose `TAG` also picks the base image. Push with `make push-image TAG=<superset version>-prod REPO_URI=118388513628.dkr.ecr.ap-south-1.amazonaws.com`.
