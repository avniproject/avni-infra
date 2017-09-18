#!/bin/bash
sudo service openchs stop || true

sudo yum cache clean
sudo rm -rf /var/cache/yum
-sudo yum -y updateinfo
sudo yum -y remove openchs-server
sudo yum -y install openchs-server-${major_version}-${minor_version}

sudo service openchs start || true