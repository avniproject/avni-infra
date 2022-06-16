#!/usr/bin/env bash
## Deploys app.
# Usage: WEBAPP_ZIP_PATH=path_of_zip WEBAPP_ZIP_FILE_NAME=path_of_zip_file ./scripts/deploy-app.sh <environment>
# <environment> can be one of staging or production. It will be the inventory file that we use to deploy

set -e -x
ENVIRONMENT=$1

if [ -z "$WEBAPP_ZIP_PATH" ] || [ -z "$WEBAPP_ZIP_FILE_NAME" ]
then
  echo "Please add values for WEBAPP_ZIP_PATH and WEBAPP_ZIP_FILE_NAME in the environment"
  exit 1
fi

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

cd ${DIR}/../

ansible-playbook -i ${ENVIRONMENT} webservers.yml
