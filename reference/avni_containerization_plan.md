# Plan: Containerize Avni Infrastructure (Issue #7)

## Context

Avni's growing microservices architecture currently deploys via Ansible+systemd/PM2 to EC2 VMs behind Classic Load Balancers (CLBs). This causes operational friction: no auto-scaling, manual SSL renewal, complex per-service systemd/PM2 management, no unified observability. The goal is to containerize all services and move to Kubernetes (EKS), enabling auto-scaling, zero-downtime deployments, and unified observability.

**Services to containerize:**
| Service | Port | Runtime | Dockerfile exists? |
|---------|------|---------|-------------------|
| avni-server | 8021 | Java (amazoncorretto:21) | Yes (avni-server/Dockerfile) |
| avni-webapp | 80 | Nginx (serves React static build) | Yes (needs redesign — sidecar pattern) |
| rules-server | varies | Node.js 10 | Yes (rules-server/Dockerfile) |
| etl-server | 8022 | Java | No |
| integration-service | 6013 | Java | No |
| avni-media | 3010 | NestJS/Node.js | No |
| avni-ai (MCP) | 8023 | Python 3.13 / FastMCP | No |
| Keycloak | — | Docker (already) | Already containerized |
| Metabase | 3000 | Docker (already) | Already containerized |
| JasperServer | 8080 | Docker (already) | Already containerized |
| Superset | 8088 | Docker + K8s (already) | Already on K8s |

**What already exists in avni-infra:**
- `configure/roles/docker/` — generic Docker Ansible role (used by Metabase, JasperServer, Keycloak)
- `reportingSystem/superset/kubernetes/` — established K8s manifest + Nginx Ingress + ECR pattern
- `reportingSystem/superset/Makefile` — `build-image`/`push-image` ECR pattern to replicate
- ELB: Classic Load Balancers with ACM wildcard cert (`*.avniproject.org`), health check on `/ping`
- RDS: PostgreSQL 12.7 on `serverdb.openchs.org` (prod), `stagingdb.openchs.org`, `prereleasedb.avniproject.org`
- S3: `<env>-user-media` buckets with versioning, IAM users for access
- Cognito: Per-environment user pools for auth
- Route53: `openchs.org` hosted zone, Alias records pointing to ELBs

**Load Balancer decision:** Keep Nginx Ingress Controller (matches existing Superset pattern in repo), fronted by CLB.
**RWB environments:** Separate follow-on effort (different AWS account).

---

## Phase 1: Docker Image Readiness (Weeks 1–4)

**Goal:** Every service has a production-grade image in ECR. No deployment changes yet.

### 1.1 Create / Fix Dockerfiles (in respective source repos)

| Service | Action | Key Changes |
|---------|--------|-------------|
| avni-server | Fix `avni-server/Dockerfile` | Add non-root user; `HEALTHCHECK` on `/ping`; shell-form `ENTRYPOINT` to support `$JAVA_OPTS` env var |
| avni-webapp | Rewrite `avni-webapp/Dockerfile` | Replace sidecar (`sleep infinity`) with `FROM nginx:alpine` + entrypoint script for runtime `REACT_APP_*` env injection |
| rules-server | Fix `rules-server/Dockerfile` | Keep `node:10` for parity; fix `CMD` to `node src/index.js` (remove `npm start`); document Node upgrade as follow-on |
| etl-server | Create new Dockerfile in `avni-etl/` | Clone avni-server pattern: `FROM amazoncorretto:21`, non-root user, `HEALTHCHECK` on `/ping` |
| integration-service | Create new Dockerfile in `integration-service/` | Same as etl-server; health check on `/ping` or `/actuator/health` |
| avni-media | Create new Dockerfile in `avni-media/` | `FROM node:20-alpine`, build NestJS app, non-root user, expose 3010, `HEALTHCHECK` on `/health` |
| avni-ai | Create new Dockerfile in `avni-ai/` | `FROM python:3.13-slim`, install via `uv`, non-root user, expose 8023, `HEALTHCHECK` on `/health` |

### 1.2 ECR Repositories + Image Build Makefiles in avni-infra

Following `reportingSystem/superset/Makefile` exactly (`build-image`, `push-image`, `run-container` with `REPO_URI` and `TAG` variables):

**New files in avni-infra:**
- `configure/docker/avni-server/Makefile`
- `configure/docker/etl-server/Makefile`
- `configure/docker/integration-service/Makefile`
- `configure/docker/rules-server/Makefile`
- `configure/docker/avni-webapp/Makefile`
- `configure/docker/avni-media/Makefile`
- `configure/docker/avni-ai/Makefile`

### 1.3 CI/CD Image Build Workflows

Build workflows in each source repo (triggered on tag push, push to ECR). Corresponding deploy workflows in avni-infra come in Phase 3.

**New files in avni-infra:**
- `.github/workflows/build-avni-server-image.yml`
- `.github/workflows/build-etl-server-image.yml`
- `.github/workflows/build-integration-service-image.yml`
- `.github/workflows/build-rules-server-image.yml`
- `.github/workflows/build-avni-webapp-image.yml`
- `.github/workflows/build-avni-media-image.yml`
- `.github/workflows/build-avni-ai-image.yml`

### Verify Phase 1
- `docker run --env-file <env-file> <image>:<tag>` starts for each service
- Health endpoint responds (e.g., `/ping` for Java services, `/health` for avni-ai/avni-media)
- Images visible in ECR console

---

## Phase 2: Docker on Existing VMs — Staging/Prerelease (Weeks 5–8)

**Goal:** Replace systemd/PM2 deployment with Docker containers on existing EC2 VMs for staging and prerelease. Production stays on systemd. Uses the existing `configure/roles/docker/` Ansible role.

### 2.1 New Docker Ansible Roles

Create Docker wrapper roles parallel to existing systemd roles. Each follows the Metabase/JasperServer pattern: call `include_role: name: docker` with container-specific defaults.

**New Ansible role directories:**
- `configure/roles/avni_appserver_docker/` — wraps `docker` role; env file is a mechanical transform of `configure/roles/avni_appserver/templates/appserver.conf.j2` (all `export VAR=value` → flat `VAR=value` Docker env file)
- `configure/roles/etl_appserver_docker/` — same pattern for ETL env vars
- `configure/roles/int_appserver_docker/` — same for integration-service env vars
- `configure/roles/rules_server_docker/` — replaces NVM+PM2 complexity with single container
- `configure/roles/avni_media_docker/` — NestJS media server
- `configure/roles/avni_ai_docker/` — Python MCP server (replaces uv+systemd setup in `avni_mcpserver` role)

Each role structure:
```
roles/<service>_docker/
  defaults/main.yml      # container_name, image URI, port mapping, healthcheck_cmd, env_file path
  tasks/main.yml         # calls: include_role: name: docker
  templates/<svc>.env.j2 # flat VAR=value file (Docker --env-file format)
```

**Critical reference for env var mapping:**
- `configure/roles/avni_appserver/templates/appserver.conf.j2` → avni-server env file
- `configure/roles/avni_mcpserver/templates/mcp_env.j2` → avni-ai env file

### 2.2 New Playbooks + Makefile Targets

**New playbooks** (parallel to existing `*_avni_servers.yml`, using `_docker` roles):
- `configure/staging_avni_servers_docker.yml`
- `configure/staging_etl_servers_docker.yml`
- `configure/staging_integration_servers_docker.yml`
- `configure/staging_rules_server_docker.yml`
- `configure/staging_media_servers_docker.yml`
- `configure/staging_ai_servers_docker.yml`
- Same set for `prerelease_*`

**Modify `configure/Makefile`** — add Docker-variant deploy targets. Replace `check-app-zip-path` prerequisite with `image_tag` variable:
```makefile
deploy-avni-server-staging-docker:
    IMAGE_TAG=$(image_tag) ansible-playbook staging_avni_servers_docker.yml \
      -i inventory/staging --vault-password-file ${VAULT_PASSWORD_FILE} \
      --extra-vars '{"avni_server_container_version":"$(image_tag)"}'
```

**Modify `configure/group_vars/basic_docker_vars.yml`** — add image URI variables:
```yaml
avni_server_container_image: "<account>.dkr.ecr.ap-south-1.amazonaws.com/avniproject/avni-server"
etl_server_container_image: "<account>.dkr.ecr.ap-south-1.amazonaws.com/avniproject/etl-server"
# ... etc per service
```

### Verify Phase 2
- `docker ps` on staging server shows containers running
- `curl https://staging.avniproject.org/ping` responds (Nginx still proxies to port 8021 — no networking change)
- Rollback: re-run playbook with previous image tag, confirm service recovers
- avni-media: media upload/download via S3 works (IAM credentials pass through env file)

---

## Phase 3: Kubernetes Staging (Weeks 9–15)

**Goal:** All services on a new EKS staging cluster. Existing VM-based staging runs in parallel until fully verified.

### 3.1 EKS Cluster Config

**New file: `kubernetes/cluster-staging.yml`** (eksctl ClusterConfig)

Tier-based node groups for cost efficiency at staging:
- `avni-staging` (t3.medium, 1–4 nodes): avni-server, webapp, rules-server, avni-media
- `background-staging` (t3.small, 1 node): etl-server, integration-service (replicas: 1 — stateful)
- `ai-staging` (t3.small, 1 node): avni-ai (Python — separate for resource isolation)

Labels: `environment: staging, tier: <tier>` (used in nodeSelector on deployments)

### 3.2 K8s Manifests Directory

Following `reportingSystem/superset/kubernetes/` pattern:

```
kubernetes/
  staging/
    kustomization.yml              # Kustomize image tag overrides per environment
    avni-server/
      namespace.yml
      configmap.yml                # Non-secret AVNI_* / OPENCHS_* vars
      secret.yml                   # DB passwords, Keycloak secret, Cognito client IDs, IAM keys
      deployment.yml               # ECR image; resources: requests.memory=2560Mi; liveness+readiness on /ping
      service.yml                  # ClusterIP, port 8021
      hpa.yml                      # min 1, max 4 replicas; CPU 70% threshold
    etl-server/
      {namespace,configmap,secret,deployment,service}.yml  # replicas: 1
    integration-service/
      {namespace,configmap,secret,deployment,service}.yml  # replicas: 1
    rules-server/
      {namespace,deployment,service}.yml                   # no secrets; port varies
    avni-webapp/
      {namespace,configmap,deployment,service}.yml         # nginx:alpine; ConfigMap for nginx.conf
    avni-media/
      {namespace,configmap,secret,deployment,service}.yml  # S3 IAM creds in Secret; port 3010
    avni-ai/
      {namespace,configmap,secret,deployment,service}.yml  # OpenAI key in Secret; port 8023
    ingress/
      avni-ingress.yml             # Nginx Ingress routes: /api→avni-server, /→webapp, /media→avni-media
      cert-manager-issuer.yml      # ClusterIssuer for Let's Encrypt (replaces Certbot Ansible role)
```

**Key config decisions:**
- **Source of truth for env vars:** `configure/roles/avni_appserver/templates/appserver.conf.j2` maps every config needed in ConfigMap/Secret
- **Secrets:** K8s Secret resources (not ConfigMap) for passwords, API keys, IAM credentials
- **avni-webapp nginx.conf:** ConfigMap-mounted, proxies `/api` requests to avni-server ClusterIP
- **ETL + integration-service:** `replicas: 1` — horizontal scaling requires application-level idempotency audit first
- **Ingress:** Nginx Ingress Controller (matching existing Superset pattern); CLB fronts it

### 3.3 AWS Networking for EKS Staging

The existing VPC (staging: 10.20.0.0/16) is reused. EKS worker nodes join the same VPC.

**Security Group changes needed:**
- EKS node SG: allow ingress 5432 from RDS SG (PostgreSQL)
- EKS node SG: allow ingress from Minio port if using `minio-staging.avniproject.org`
- RDS SG: add EKS worker node SG as allowed source on port 5432
- CLB SG: forward to Nginx Ingress NodePort (instead of direct EC2 port 8021)

**S3 access:** avni-server and avni-media need `<env>-user-media` bucket access. IAM credentials passed as K8s Secrets (existing IAM users continue to work; migrate to IRSA in a follow-on).

**ACM wildcard cert (`*.avniproject.org`):** Remains on CLB listeners. cert-manager handles in-cluster TLS for internal service-to-service if needed.

**Route53:** No changes until cutover. Staging K8s tested via a separate `k8s-staging.avniproject.org` CNAME.

### 3.4 K8s Deploy Workflow

**New file: `.github/workflows/deploy-staging-k8s.yml`**

Steps: authenticate to ECR → update image tag in kustomization.yml → `kubectl apply -k kubernetes/staging/` → `kubectl rollout status`

### Verify Phase 3
- `kubectl get pods -A` — all pods Running
- `curl https://k8s-staging.avniproject.org/ping` — avni-server responds
- Webapp loads, API calls succeed end-to-end
- ETL job runs to completion
- Media upload via avni-media persists to S3
- avni-ai `/health` responds
- Simulate pod kill: new pod starts within 30s
- HPA test: simulate load, confirm avni-server scales to 2+ replicas

---

## Phase 4: Kubernetes Production + Observability (Weeks 16–24)

**Goal:** All services on EKS production cluster. Full observability. Automated deployments. Gradual traffic cutover.

### 4.1 Production Cluster

**New file: `kubernetes/cluster-prod.yml`**

Per-service node groups (isolation + independent scaling, matching Superset pattern):
- `avni-server-prod` (t3.large, 2–6 nodes, min 2 for HA): JVM needs 2560m–5120m RAM
- `webapp-prod` (t3.small, 1–3 nodes): lightweight static Nginx
- `rules-server-prod` (t3.small, 1–3 nodes)
- `etl-prod` (t3.medium, 1–2 nodes): background jobs
- `integration-prod` (t3.small, 1 node): stateful outbound API calls
- `avni-media-prod` (t3.small, 1–2 nodes)
- `avni-ai-prod` (t3.small, 1–2 nodes)

Labels: `environment: prod, app: <service>` (matches Superset's per-app nodeSelector pattern)

### 4.2 Production Manifests

**New directory: `kubernetes/prod/`** (same structure as staging with production values):
- avni-server: `replicas: 2` (HA); `resources: {requests: {memory: "2560Mi", cpu: "500m"}, limits: {memory: "5120Mi"}}`; PodDisruptionBudget `minAvailable: 1`
- All services: production ECR image tags pinned (not `latest`)
- avni-server: `external-secret.yml` using External Secrets Operator → AWS Secrets Manager (secrets already exist as Ansible Vault encrypted vars; migrate paths to Secrets Manager `avni/prod/avni-server`)

### 4.3 Observability Stack

**New files in `kubernetes/observability/`:**
- `fluentbit-daemonset.yml` — forwards container stdout/stderr to CloudWatch Logs Groups per service
- `prometheus-configmap.yml` — scrapes Spring Boot Actuator (`/actuator/prometheus`) on Java services

**Modify deployments:** Remove `-Dlogging.file.name` JVM flag (log to stdout). Add Prometheus scrape annotations:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8021"
```

**Alerting (CloudWatch Alarms):**
- CPU > 80% sustained 5min
- Memory > 85%
- Pod restarts > 3 in 10min
- ELB 5xx rate > 1%

### 4.4 Database — No Migration Needed

RDS remains external. Services continue using `OPENCHS_DATABASE_HOST`, `stagingdb.openchs.org`, `serverdb.openchs.org` etc. via K8s Secret/ConfigMap. Only networking change: add EKS prod node SG to RDS SG on port 5432.

### 4.5 Production Cutover

1. Deploy to K8s prod → smoke test on `k8s-prod.avniproject.org` (separate Route53 CNAME)
2. Route 10% traffic to K8s prod via Route53 weighted routing, monitor 24h
3. Route 100% traffic to K8s prod, update Route53 Alias from CLB→EKS CLB
4. Keep EC2 VM instances running 1 week as hot standby
5. Decommission VM deployment after stability confirmed

### Verify Phase 4
- Zero-downtime rolling deploy: no 5xx during `kubectl set image`
- HPA: avni-server scales out under simulated load, scales back
- PDB: verify node drain doesn't take all avni-server pods offline simultaneously
- DR: terminate one AZ's nodes, avni-server continues from remaining AZ
- Logs appear in CloudWatch within 60s of pod start
- Secret rotation: update value in Secrets Manager → ESO syncs to K8s Secret

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Ingress | Nginx Ingress Controller + CLB | Matches existing Superset pattern in repo; team familiarity |
| avni-webapp image | Self-contained nginx:alpine | Sidecar pattern dead-end for K8s; nginx is simpler and standard |
| rules-server Node version | Keep node:10 in Phase 1–2 | Avoid scope explosion; upgrade before Phase 3 K8s (security risk in prod K8s) |
| ETL/integration replicas | 1 replica each | Stateful behavior — ETL job locks, integration idempotency not yet audited |
| Secret management (prod) | External Secrets Operator + AWS Secrets Manager | Secrets already managed in AWS; ESO avoids duplication |
| Manifest templating | Kustomize | Familiar overlay pattern; no Helm complexity for internal use |
| Phase 2 (Docker on VMs) | Include it | Low incremental cost using existing docker role; validates images before K8s |
| RWB environments | Follow-on effort | Separate AWS account requires separate planning track |
| on-premise | Out of scope | User explicitly excluded |

---

## Critical Files

| File | Role in Implementation |
|------|------------------------|
| `configure/roles/docker/tasks/main.yml` | Phase 2 new roles call this via `include_role: name: docker` |
| `configure/roles/avni_appserver/templates/appserver.conf.j2` | Source of truth for all avni-server env vars → Docker env file + K8s ConfigMap/Secret |
| `configure/roles/avni_mcpserver/templates/mcp_env.j2` | Source of truth for avni-ai env vars |
| `reportingSystem/superset/kubernetes/superset-prod-deployment.yml` | K8s manifest pattern to replicate for all services |
| `reportingSystem/superset/Makefile` | Image build/push/run pattern for all Phase 1 Makefiles |
| `configure/group_vars/basic_docker_vars.yml` | Extend with image URI variables in Phase 2 |
| `configure/Makefile` | Add Docker deploy targets in Phase 2 |
| `configure/group_vars/staging_vars.yml`, `prod_vars.yml` | Source for environment-specific values in K8s ConfigMaps |

---

## Summary Timeline

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| 1 — Docker Images | Weeks 1–4 | All 7 services have ECR images + CI build pipelines |
| 2 — Docker on VMs | Weeks 5–8 | Staging/prerelease running containers on existing EC2 (zero K8s risk) |
| 3 — K8s Staging | Weeks 9–15 | Full EKS staging cluster, Nginx Ingress, all services running |
| 4 — K8s Production | Weeks 16–24 | EKS prod HA, observability, gradual cutover, VM decommission |
