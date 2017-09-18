#!/bin/bash
sudo service openchs stop || true

sudo yum -y install openchs-server-${major_version}-${minor_version}

sudo service openchs start || true