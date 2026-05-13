## Run Command — reference only

Routine deployments use Ansible (`make tanuh-metabase-prod` in `configure/`). This document records the equivalent `docker run` for ad-hoc operator use (e.g., restoring a container manually if Ansible can't reach the host).

```bash
docker run \
  --name=tanuh_metabase \
  --hostname=tanuh-metabase \
  --env-file=/root/tanuh_metabase_docker.env \
  --memory=3.5g \
  -p 3000:3000 \
  --restart=always \
  --log-opt max-size=10m \
  --log-opt max-file=10 \
  --runtime=runc \
  --detach=true \
  118388513628.dkr.ecr.ap-south-1.amazonaws.com/avniproject/tanuh-metabase:<version>
```

The env file is rendered by Ansible from `configure/roles/metabase/templates/metabase.docker.env.template.j2` using values from `configure/group_vars/tanuh_metabase_docker_vars.yml` + `configure/group_vars/prod-secret-vars.yml.enc`.
