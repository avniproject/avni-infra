## Steps of migrations

---

### Backup

1. Stop superset service. copy superset db into your local and take backup

```shell
scp -i ~/.ssh/openchs-infra.pem  ubuntu@reporting-superset.avniproject.org:/home/superset/.superset/superset.db .
scp -i ~/.ssh/openchs-infra.pem  ubuntu@reporting-superset.avniproject.org:/home/superset/superset_config.py . 
```
---


### install docker
1. follow below command to install docker [Official guide](https://docs.docker.com/desktop/install/ubuntu/)
```shell
sudo apt-get update
sudo snap install docker
sudo chown ubuntu /var/run/docker.sock
sudo chmod 660 /var/run/docker.sock
```



### remove values from superset.db

1. use [/assets/mismatch_data_superset_sqllite.sql](https://github.com/avniproject/avni-infra/blob/master/reportingSystem/superset/assets/mismatch_data_superset_sqllite.sql) to remove the record (currently it is causing issue in primary key)


---
### Upgrate to docker 2.0.1 and postgres

1. create network for superset and run superset(2.0.1)  
```shell
docker network create superset_network

docker run -d  -p 8088:8088  --network superset_network  --name superset_2.0.1 apache/superset:2.0.1

docker exec -it  -u root superset_2.0.1 bash

apt-get update && apt-get install vim

vim superset_config.py

export SUPERSET_CONFIG_PATH=/app/superset_config.py
```

2. paste content of [/assets/superset_config.py](https://github.com/avniproject/avni-infra/blob/master/reportingSystem/superset/assets/superset_config.py) file && change the database to postgres with flag **SQLALCHEMY_DATABASE_URI**

3. restart the docker it will create metadata in postgres database. here we don't do superset init becuase it creates it's own record which cause issue in primary key
```shell
docker exec -it  -u root superset_2.0.1 bash
superset db upgrade
```

4. change source & destination in [/assets/pgloaderdataonly.conf](https://github.com/avniproject/avni-infra/blob/master/reportingSystem/superset/assets/pgloaderdataonly.conf) tunnel the postgres db and transfer the data.
```shell
## change as per environment
ssh -o ConnectTimeout=30 -N  -L 5433:prereleasedb.avniproject.org:5432 ubuntu@ssh.prerelease.avniproject.org -i ~/.ssh/openchs-infra.pem
## go to second windoow
pgloader pgloaderdataonly.conf | tee db_transfer.txt
```

5. now check the db_transfer.txt and if error then try to resolve and don't move ahead


6. reset the sequence [/assets/reset_sequence.sql](https://github.com/avniproject/avni-infra/blob/master/reportingSystem/superset/assets/reset_sequence.sql) .so, we don't get error for further update. if sequence not used and give error ignore that.

7. remove schema from the table [/assets/remove_schema.sql](https://github.com/avniproject/avni-infra/blob/master/reportingSystem/superset/assets/remove_schema.sql). 
Superset removed schema search for public. [Reference](https://github.com/apache/superset/blob/4.0.2/superset/db_engine_specs/postgres.py#L256)

8. go to container and run db commands. if any error then try to resolve here. don't move further
```shell
docker exec -it  -u root superset_2.0.1 bash
superset db upgrade
superset db init
```

---
### Upgrate to superset docker 4.0.1 (from avni ecr image)


1. stop the superset_2.0.1. 
```shell
docker stop superset_2.0.1
```

2. image push to ecr repo (do if image is not set)
```shell
aws configure #if not done
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin 118388513628.dkr.ecr.ap-south-1.amazonaws.com
make push-image REPO_URI=118388513628.dkr.ecr.ap-south-1.amazonaws.com
```

3. copy environment file to supersetdata and configure aws [AWS CLI download reference](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
```shell
aws --version
# if error then install aws cli
aws configure
#provide access key and secret
mkdir supersetdata
cd supersetdata
# paste file superset.env from secrets
```

4. run docker for 4.0.1
```shell
sudo mkdir -p /var/log/superset

sudo chmod -R 777 /var/log/superset

aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin 118388513628.dkr.ecr.ap-south-1.amazonaws.com

docker pull 118388513628.dkr.ecr.ap-south-1.amazonaws.com/avniproject/reporting-superset:4.0.1

docker run -d -p 8088:8088 \
    --name avnisuperset_4.0.1 \
    --env-file ~/supersetdata/superset.env \
    -v /var/log/superset:/app/superset_home \
    118388513628.dkr.ecr.ap-south-1.amazonaws.com/avniproject/reporting-superset:4.0.1
    
docker logs -f avnisuperset_4.0.1

tail -f /var/log/superset/superset.log

docker exec -it  -u root avnisuperset_4.0.1 bash
superset db upgrade
superset db init  
```

5. important commands for docker container
```shell
docker logs -f avnisuperset_4.0.1
docker exec -it  -u root avnisuperset_4.0.1 bash
docker start avnisuperset_4.0.1
docker stop avnisuperset_4.0.1
docker restart avnisuperset_4.0.1
docker inspect avnisuperset_4.0.1
```

6. generate certificate for testing superset (optional)
```shell
sudo certbot --nginx -d test-reporting-superset.avniproject.org
sudo certbot renew --cert-name test-reporting-superset.avniproject.org 
```



### Post Deployment Task
1. Go to ec2 and flag and after completing task remove that
```shell
#ssh to ec2
docker exec -it -u root avnisuperset_4.0.1 bash
#you are inside docker
vi superset_config.py
# add flag : FAB_ADD_SECURITY_API = True
superset init
exit
#outside container
docker restart avnisuperset_4.0.1
```

2. Add permissions to role. First take ids from file [/assets/role_permission_upgrade.sql](https://github.com/avniproject/avni-infra/blob/superset/reportingSystem/superset/assets/role_permission_upgrade.sql). put it into [/assets/RoleUpgrade.js](https://github.com/avniproject/avni-infra/blob/superset/reportingSystem/superset/assets/RoleUpgrade.js)
and run scripts.

```bash
nvm use;
npm install
node superset/assets/RoleUpgrade.js
```

