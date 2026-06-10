#!/usr/bin/env bash
#
# Roll back aws_ci_setup.sh: delete the GHA role + ECR repo for tanuh-superset.
# The shared GitHub OIDC provider is intentionally NOT deleted (other roles use it).
#
# Usage:  bash aws_ci_teardown.sh        # prompts before deleting
#         FORCE=1 bash aws_ci_teardown.sh
#
set -euo pipefail

REGION=${REGION:-ap-south-1}
ECR_REPO_NAME=avniproject/tanuh-superset
GHA_ROLE_NAME=tanuh-superset-gha-role
GHA_POLICY_NAME=tanuh-ecr-push

log() { echo "[ci_teardown] $*"; }

if [[ "${FORCE:-0}" != "1" ]]; then
  read -r -p "Delete role ${GHA_ROLE_NAME} and ECR repo ${ECR_REPO_NAME} (incl. images)? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { log "Aborted."; exit 0; }
fi

log "Deleting inline policy + role $GHA_ROLE_NAME..."
aws iam delete-role-policy --role-name "$GHA_ROLE_NAME" --policy-name "$GHA_POLICY_NAME" 2>/dev/null || true
aws iam delete-role --role-name "$GHA_ROLE_NAME" 2>/dev/null || true

log "Deleting ECR repo $ECR_REPO_NAME (force: removes images)..."
aws ecr delete-repository --region "$REGION" --repository-name "$ECR_REPO_NAME" --force 2>/dev/null || true

log "Done. OIDC provider left in place (shared)."
