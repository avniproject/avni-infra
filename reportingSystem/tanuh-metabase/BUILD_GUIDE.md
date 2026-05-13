# Tanuh Metabase Docker Image Build Guide

## Overview

The Tanuh Metabase image extends the official `metabase/metabase` image with custom branding assets (logo, favicon).

The image is consumed by the Tanuh Metabase EC2 in prod, deployed via Ansible (`make tanuh-metabase-prod` in `configure/`).

## Image tag — single source of truth

The image tag lives in `VERSION` in this directory. Every consumer reads from this one file:

- `Makefile` — `TAG := $(shell cat VERSION)`
- `.github/workflows/build-tanuh-metabase.yml` — `cat reportingSystem/tanuh-metabase/VERSION`
- `configure/group_vars/tanuh_metabase_docker_vars.yml` — `lookup('file', '…/VERSION') | trim`

To release a new image: bump `VERSION`, push a git tag matching `tanuh-metabase-v*`, let the CI workflow build/push, then run `make tanuh-metabase-prod` from `configure/`.

## Routine builds happen in CI

The `.github/workflows/build-tanuh-metabase.yml` workflow builds and pushes the image automatically on:

- Push of a git tag matching `tanuh-metabase-v*`.
- Manual `workflow_dispatch` (useful for testing branches; pushes a `:dev-<sha>` tag).

It uses GitHub OIDC to assume the `tanuh-metabase-gha-role` IAM role provisioned by `aws_setup.sh`. No long-lived credentials are stored in the repo.

## Local builds (troubleshooting only)

```bash
cd reportingSystem/tanuh-metabase
make build-image
# Test locally with dummy env vars
docker run -d -p 3000:3000 \
  -e MB_DB_TYPE=postgres \
  -e MB_DB_HOST=<host> -e MB_DB_PORT=5432 \
  -e MB_DB_DBNAME=tanuh_reporting_db \
  -e MB_DB_USER=<user> -e MB_DB_PASS=<pw> \
  --name tanuh_metabase_smoke avniproject/tanuh-metabase:$(cat VERSION)
curl http://localhost:3000/api/health
```

## Pushing manually (only if CI is unavailable)

```bash
export REPO_URI=118388513628.dkr.ecr.ap-south-1.amazonaws.com
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin $REPO_URI
make build-image push-image
```

## Branding assets

`assets/logo.png` and `assets/favicon.ico` are copied into the image at `/app/branding/`. OSS Metabase does not read these from disk at runtime — they are baked in as placeholders pending a public URL.

Final wiring: after deployment, an admin sets **Admin → Settings → Application Logo URL / Favicon URL** to a public URL serving these files (S3 + CloudFront, or the avni-website repo). Tracked as a follow-up.

## Important considerations

- **Base image version**: bump only after reviewing Metabase release notes for breaking changes (especially around app-DB migrations).
- **Multi-arch**: image is built for `linux/amd64` only (matches `t3.medium` EC2). Local builds on Apple Silicon will use buildx emulation.
- **Image scanning**: ECR repo has `scanOnPush=true` — review scan results before pinning a new tag in production.

---

**Last Updated**: 2026-05-13
