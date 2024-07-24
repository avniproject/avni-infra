### References :
[Configuration](https://superset.apache.org/docs/configuration/configuring-superset/)
[Python Update](https://superset.apache.org/docs/installation/pypi)
[Virtual env](https://medium.com/@adocquin/mastering-python-virtual-environments-with-pyenv-and-pyenv-virtualenv-c4e017c0b173)


### Backup sql lite db, superset_config.py and superset.sh

```sh
scp -i ~/.ssh/openchs-infra.pem  ubuntu@3.109.124.133:/home/superset/.superset/superset.db .
scp -i ~/.ssh/openchs-infra.pem  ubuntu@3.109.124.133:/home/superset/superset_config.py . 
scp -i ~/.ssh/openchs-infra.pem  ubuntu@3.109.124.133:/home/superset/superset.sh .
```



### Commands to update

1. login with superset user and stop superset service

```sh
sudo -i -u superset
sudo systemctl stop superset.service
sudo systemctl status superset.service
```

2. (If unable to login) use this command and again use step 1 command.

```sh
sudo usermod -s /bin/bash superset
```


3. penv add python 3.11.9. if you are getting error then resolve here. uninstall that version and then again reinstall. most are related to driver which we added in apt-get command.

```sh
pyenv uninstall superset
pyenv uninstall 3.11.9
sudo apt-get update  
sudo apt-get install build-essential libssl-dev libffi-dev python3-dev python3-pip libsasl2-dev libldap2-dev default-libmysqlclient-dev libsqlite3-dev libbz2-dev libncurses5-dev libreadline-dev lzma liblzma-dev libbz2-dev
pyenv install -l
pyenv install 3.11.9
pyenv update
pyenv versions
pyenv local 3.11.9
```

4. creating venv and install specific version of superset and upgrade superset db and init

```sh
pyenv virtualenv 3.11.9 superset 
pyenv activate superset
pip3 install --upgrade pip
pip install psycopg2-binary 
pip install 'apache-superset==4.0.2'
export SUPERSET_CONFIG_PATH=/home/superset/superset_config.py
export FLASK_APP=superset
superset version
## perform superset db upgrade and init
superset db upgrade
superset init
source deactivate
```

5. change superset.sh


### content of superset.sh should be follow

```sh
pyenv activate superset 
export SUPERSET_CONFIG_PATH=/home/superset/superset_config.py
export FLASK_APP=superset
superset run -p 8088 --with-threads --reload --debugger
```

6. if any new feature want then check documentation and add those flags in superset_config.py


7. No change is service file use below command for service. Ensure that superset sqlite db file superset.db is present in /home/superset/.superset

```sh
sudo systemctl start superset.service
sudo systemctl status superset.service
-- sudo systemctl stop superset.service
```