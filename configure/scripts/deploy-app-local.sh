#!/usr/bin/env bash
set -e -x

eval `ssh-agent`
ssh-add ~/.ssh/test_bp_ansible_id_rsa

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

${DIR}/deploy-app.sh $@