#sleep 5
sudo apt-get update
sudo apt-get upgrade -y

##Install OpenJDK 8
sudo apt-get install -y openjdk-8-jdk
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64

##Install tomcat 9
sudo apt-get install -y tomcat9

##Install other dependencies
sudo apt-get install -y unzip
sudo apt-get install -y zip
sudo apt-get install -y awscli

##Install jasper-server
[ -f ~/jasper-server.zip ] || aws s3 cp s3://openchs/binaries/TIB_js-jrs-cp_7.5.0_bin.zip ~/jasper-server.zip
unzip jasper-server.zip

cd jasperreports-server-cp-7.5.0-bin/buildomatic/
aws s3 cp s3://openchs/binaries/jasper-config/default_master.properties default_master.properties
sudo mkdir /opt/jasper-config
sudo chmod o+rw /opt/jasper-config
export ks=/opt/jasper-config
export ksp=/opt/jasper-config

sudo chmod -R o+rw /usr/share/tomcat9/lib/
sudo chmod -R o+rw /var/lib/tomcat9/webapps/

./js-install-ce.sh minimal

sudo chmod o+r /opt/jasper-config/.*

##Mitigate Log4Shell (CVE-2021-44228) in the bundled Jasper 7.5.0 log4j
## Jasper 7.5.0 ships log4j-core 2.12.1 with JndiLookup.class, which is vulnerable.
## Remove that class from every bundled log4j-core jar so a rebuild is not vulnerable.
## Stop-gap until Jasper is upgraded to 8.2.0+ (which bundles patched log4j). See
## avniproject/avni-infra#122 and docs/security/2026-11-09-jasper-log4shell-mitigation.md
sudo find /var/lib/tomcat9/webapps/jasperserver -name 'log4j-core-*.jar' \
  -exec zip -q -d {} 'org/apache/logging/log4j/core/lookup/JndiLookup.class' \; || true

#Restart tomcat
sudo service tomcat9 restart
