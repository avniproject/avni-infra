#!/bin/bash
sudo service openchs stop || true

sudo yum clean all 2>&1 >/dev/null
sudo rm -rf /var/cache/yum 2>&1 >/dev/null
sudo yum -y updateinfo 2>&1 >/dev/null
sudo yum -y remove openchs-server 2>&1 >/dev/null
sudo yum -y install openchs-server-${major_version}-${minor_version} 2>&1 >/dev/null

sudo service openchs start || true

sleep 20