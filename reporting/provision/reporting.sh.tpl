set -e
export MB_PASSWORD_COMPLEXITY=strong
export MB_PASSWORD_LENGTH=12
export MB_JETTY_PORT=3000
export MB_DB_TYPE=postgres
export MB_DB_DBNAME=${db_name}
export MB_DB_PORT=${db_port}
export MB_DB_USER=${db_user}
export MB_DB_PASS=${db_password}
export MB_DB_HOST=${db_host}

sudo yum install -y java-1.8.0-openjdk-devel
rm -rf ~/metabase.jar 2>&1 > /dev/null
curl -L http://downloads.metabase.com/${metabase_version}/metabase.jar > ~/metabase.jar
sudo fuser -k 3000/tcp 2>&1 > /dev/null
sleep 5
nohup java -jar ~/metabase.jar 2>&1 >> ~/metabase.log &

sleep 20