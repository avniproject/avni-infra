# Tanuh Metabase Docker Image Build Guide

## Overview

The Tanuh Metabase image is built from Metabase OSS source code at a pinned upstream tag, with Tanuh branding (header logo, app name, favicon, browser tab title) applied via patches + file overlays during the Docker build.

This is **not** the simpler `FROM metabase/metabase:...` overlay pattern — OSS Metabase doesn't read branding from env vars or disk paths, so the only way to white-label it is to rebuild from source.

The image is consumed by the Tanuh Metabase EC2 in prod, deployed via Ansible (`make tanuh-metabase-prod` in `configure/`).

## What the build does

1. Stage 1 (`builder`):
   - Installs JDK 21, Clojure 1.12, Node 22, bun.
   - Shallow-clones `metabase/metabase` at the upstream tag derived from `VERSION` (e.g. `v0.60.4.1`).
   - Sanity-checks that all overlay-target paths still exist upstream (fail loud if Metabase moved them).
   - Applies `patches/*.patch` (currently: change `application-name` and `site-name` defaults to "Tanuh" in `src/metabase/appearance/settings.clj`).
   - Overlays `files/LogoIcon.tsx` and `assets/logo.png` (replaces the inline-SVG Metabase logo with the Tanuh PNG).
   - Pulls the Tanuh favicon from the avni-webapp repo.
   - Runs `bin/build.sh` to produce `target/uberjar/metabase.jar`.

2. Stage 2 (`runner`):
   - Starts from `eclipse-temurin:21-jre-alpine`.
   - Installs Noto fonts, imports the AWS RDS CA bundle (needed for SSL to prod RDS).
   - Copies `metabase.jar` + `run_metabase.sh` from the builder stage.
   - Exposes 3000.

## Image tag — single source of truth

The image tag lives in `VERSION` in this directory. Every consumer reads from this one file:

- `Makefile` — `TAG := $(shell cat VERSION)`, `METABASE_VERSION := $(shell echo $(TAG) | sed 's/-tanuh-.*//')`
- `.github/workflows/build-tanuh-metabase.yml` — `cat reportingSystem/tanuh-metabase/VERSION`
- `configure/group_vars/tanuh_metabase_docker_vars.yml` — `lookup('file', '…/VERSION') | trim`

Tag format: `<upstream-metabase-version>-tanuh-<N>` (e.g. `v0.60.4.1-tanuh-2`). The `-tanuh-N` suffix increments when only Tanuh-side changes (patch tweaks, asset replacements) happen without an upstream version bump.

To release a new image: bump `VERSION`, push a git tag matching `tanuh-metabase-v*`, let the CI workflow build/push, then run `make tanuh-metabase-prod` from `configure/`.

## Routine builds happen in CI

The `.github/workflows/build-tanuh-metabase.yml` workflow builds and pushes the image automatically on:

- Push of a git tag matching `tanuh-metabase-v*`.
- Manual `workflow_dispatch` (useful for testing branches; pushes a `:dev-<sha>` tag).

The workflow uses GitHub OIDC to assume the `tanuh-metabase-gha-role` IAM role provisioned by `aws_setup.sh`. No long-lived credentials are stored in the repo. It also configures `cache-from: type=gha` / `cache-to: type=gha,mode=max` so the heavy toolchain-install layer is reused across runs (first build ~60 min, subsequent ~15 min).

Per-job timeout is set to 120 min.

## Local builds (troubleshooting only)

Source build is heavy: ~30–60 min on a fast workstation, longer with emulation. Use the simpler smoke check first (CI build with cache, then pull from ECR for inspection) before resorting to local.

```bash
cd reportingSystem/tanuh-metabase
make build-image                       # ~30–60 min cold
docker run -d -p 3000:3000 \
  -e MB_DB_TYPE=h2 \
  --name tanuh_metabase_smoke \
  avniproject/tanuh-metabase:$(cat VERSION)
curl -s http://localhost:3000/api/health
# Visit http://localhost:3000 — header logo, browser tab title, favicon
# should all show Tanuh branding.
```

## Pushing manually (only if CI is unavailable)

```bash
export REPO_URI=118388513628.dkr.ecr.ap-south-1.amazonaws.com
aws ecr get-login-password --region ap-south-1 \
  | docker login --username AWS --password-stdin $REPO_URI
make build-image push-image
```

## Branding overlays

| What | How it gets applied |
|---|---|
| Header logo (top-left in UI) | `files/LogoIcon.tsx` replaces `frontend/src/metabase/common/components/LogoIcon/LogoIcon.tsx`. The replacement renders an `<img>` pointing at `app/assets/img/logo.png`. |
| Logo image | `assets/logo.png` is copied into `resources/frontend_client/app/assets/img/logo.png` during build. |
| App name ("Metabase" → "Tanuh") | `patches/0001-tanuh-appearance-defaults.patch` changes the `:default` of `application-name` and `site-name` in `src/metabase/appearance/settings.clj`. |
| Browser tab title | Picks up automatically — `index_template.html` renders `<title>{{{applicationName}}}</title>` server-side, sourcing from the `application-name` setting. |
| Favicon | Pulled from `https://github.com/avniproject/avni-webapp/raw/master/public/favicon.ico` during build and copied to both `resources/frontend_client/favicon.ico` and `resources/frontend_client/app/assets/img/favicon.ico`. |

## Upgrading Metabase

When bumping to a new upstream Metabase version (e.g. `v0.60.4.1` → `v0.61.x`):

1. Update `VERSION` to `vX.Y.Z-tanuh-1`.
2. Trigger a CI build (push the new tag). The pre-build sanity check (the `for f in … test -f` loop in the Dockerfile) will fail loudly if any overlay-target path moved upstream.
3. If patches fail to apply (`git apply` exits non-zero):
   - Locally: clone the upstream repo at the new tag, re-apply the failing patch with `git apply --reject patches/0001-*.patch`, fix the `.rej` files by hand, regenerate the patch with `git diff > patches/0001-*.patch`.
   - Re-check the patch with `git apply --check patches/0001-*.patch` against the new upstream content.
4. If the `LogoIcon.tsx` file moved or its imports changed, update `files/LogoIcon.tsx` to match the new upstream shape, then re-verify the Dockerfile's `COPY files/LogoIcon.tsx <upstream-path>` line still points at the right destination.
5. Smoke-test in CI first; deploy to prod via `make tanuh-metabase-prod`.

## Important considerations

- **Base image version**: bump only after reviewing Metabase release notes for breaking changes (especially around app-DB migrations).
- **Multi-arch**: image is built for `linux/amd64` only (matches `t3.medium` EC2). Local builds on Apple Silicon will use buildx emulation and take much longer.
- **Image scanning**: ECR repo has `scanOnPush=true` — review scan results before pinning a new tag in production.
- **Build-time network**: the build clones Metabase + downloads JDK/Clojure/bun/Noto fonts/RDS CA bundle. CI runners have outbound network; restricted networks won't work.

---

**Last Updated**: 2026-05-14
