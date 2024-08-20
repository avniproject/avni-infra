## Steps of migrations

---

### Backup

1. copy superset db into your local and take backup

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
ssh -o ConnectTimeout=30 -N  -L 5433:prereleasedb.avniproject.org:5432 ubuntu@ssh.prerelease.avniproject.org -i ~/.ssh/openchs-infra.pem
## go to second windoow
pgloader pgloaderdataonly.conf > db_transfer.txt
```

5. now check the db_transfer.txt and if error then try to resolve and don't move ahead


6. reset the sequence [/assets/reset_sequence.sql](https://github.com/avniproject/avni-infra/blob/master/reportingSystem/superset/assets/reset_sequence.sql) .so, we don't get error for further update. if sequence not used and give error ignore that.
   

7. go to container and run db commands. if any error then try to resolve here. don't move further
```shell
docker exec -it  -u root superset_2.0.1 bash
superset db upgrade
superset db init
```

---
### Upgrate to superset docker 4.0.1


1. stop the superset_2.0.1. copy data from  [/assets/superset_config.py](https://github.com/avniproject/avni-infra/blob/master/reportingSystem/superset/assets/superset_config.py) and add require flags and configuration
```shell
docker stop superset_2.0.1
#check /home/ubuntu/supersetdata exist or not if not then create
cd /home/ubuntu/supersetdata
vi superset_config.py
```

2. get logo of avni
```shell
cd /home/ubuntu/supersetdata
wget https://avniproject.org/static/avni-logo-color-b42a730b01c55efe37722027d9cddd95.png
mv avni-logo-color-b42a730b01c55efe37722027d9cddd95.png avni.png
```

3. run docker for 4.0.1
```shell
docker run -d -p 8088:8088 \
  --network superset_network \
  --name superset_4.0.1 \
  -e SUPERSET_CONFIG_PATH=/app/superset_config.py \
  -v /home/ubuntu/supersetdata/superset_config.py:/app/superset_config.py \
  -v /home/ubuntu/supersetdata/avni.png:/app/superset/static/assets/images/avni.png \
  apache/superset:4.0.1
docker logs -f superset_4.0.1  
```

4. important commands for docker container
```shell
docker logs -f superset_4.0.1
docker exec -it  -u root superset_4.0.1 bash
docker start superset_4.0.1
docker stop superset_4.0.1
docker restart superset_4.0.1
```

