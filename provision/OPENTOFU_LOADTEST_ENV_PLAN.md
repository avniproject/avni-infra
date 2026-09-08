# OpenTofu Plan — Reusable Avni Environment, First Instance: Load Testing

**Status:** proposed, not started
**Owner:** _unassigned_
**Created:** 2026-09-08 · **Revised:** 2026-09-08

---

## 1. Goal

Stand up a **new, disposable, production-shaped environment** for load tests to run against —
provisioned with OpenTofu and configured with the existing Ansible roles, both of which live in this
repository and are planned together here. Written as a parameterised module from the outset so the
same code provisions the dedicated customer environments and rebuilt lower environments that follow.

Greenfield. Nothing here imports, adopts or modifies any existing environment. Production is a
sizing reference only; `provision/server/` stays as-is, historical, with its warning intact.

---

## 2. Ownership boundary

This plan covers **both layers that live in this repository** — OpenTofu provisioning and the
Ansible configuration that makes the environment usable. They are tightly coupled: the access path
chosen in `provision/` determines how `configure/` reaches the hosts, and neither half delivers an
environment on its own.

| Layer | Owner | Covers |
|---|---|---|
| **AWS resources** (`provision/`) | **this plan, §§5-8** | Network, compute, RDS, S3, ALB, DNS, IAM, access path, parameter groups, cost controls |
| **Environment configuration** (`configure/`) | **this plan, §9** | Inventory, playbooks, group_vars, Makefile targets, JVM flags, pool size, log level, IdP type |
| **Test harness, workload, data, run ritual** | `avni-perf` | Simulation, scenarios, dataset generation, user provisioning, per-run procedure |

**One rule survives from the earlier split, and it is a module-design rule rather than a scope
boundary:** app-level settings do not become OpenTofu variables. JVM heap, application pool size,
log level and `AVNI_IDP_TYPE` are Ansible's, set in `group_vars` or a Makefile target. Where
infrastructure must know *about* an application setting it exposes a resource toggle instead —
`enable_cognito`, not `idp_type`.

**The corresponding database-side settings are infrastructure**, because they live in an RDS
parameter group rather than in application config: `max_connections`, `autovacuum`,
`pg_stat_statements`, `log_min_duration_statement`.

---

## 3. Infrastructure properties the harness depends on

`avni-perf/docs/sync-simulation-plan.md` now gathers these itself, in **section I — "What the
harness requires of the environment"**, with each item traced to the task that produced it. That is
the authoritative list; it is not restated here.

- **I1** network and access — no public reachability, Instance Connect Endpoint or SSM, instance-ID
  addressing, an outbound path for deploy-time package fetches, deliberate DNS, a position for the
  injector.
- **I2** application configuration — Ansible's, per §2.
- **I3** database — PostgreSQL 16.8, dedicated, production-matched parameter group and storage
  class, `pg_stat_statements` and slow query logging, **storage headroom for a second copy of the
  dataset**, and snapshot/restore for baseline creation rather than per-run reset.
- **I4** data and side effects.

**That section deliberately excludes sizing** — instance classes, storage sizes, pool values and
heap settings. Those are this plan's (§5) and Ansible's. The division is clean and worth preserving:
the harness states what must be true, this plan decides how large.

---

## 4. What "production-shaped" means at the AWS layer

| Dimension | Reference | Why it matters |
|---|---|---|
| Topology | VPC, two subnets across AZs, app host, RDS primary **+ read replica**, S3 media, load balancer | The replica exists in prod (`configure/group_vars/prod_vars.yml:48`); omitting it changes read-path behaviour |
| Host separation | avni-server and avni-etl on **separate instances** | Prod runs them apart (`configure/inventory/prod`); co-locating changes CPU and connection contention |
| Instance classes | See §5 — **deliberately not matched** | Production is burstable; the rig cannot be |
| Postgres version | Match production (16.x) | Planner behaviour is version-specific |
| Storage | gp3, sized with load-event headroom (§5, §6) | Matches production, which already runs gp3 |
| LB idle timeout | 400s | `provision/server/elb.tf`. Sync requests are long; a shorter timeout converts slow responses into errors |

**Deliberately not copied from the old Terraform:** `ami-531a4c3c`/Amazon Linux → Ubuntu;
`aws_elb` Classic → ALB; `storage_encrypted = false` → encrypted; `password = "password"` →
`manage_master_user_password`; static IAM user access keys → instance profile only; public subnet
with `0.0.0.0/0` SSH → private, no public ingress; Makefile workspace juggling with `_override.tf` →
one state per environment with plain `tfvars`.

**Application-level parity** — JVM flags, pool size, log level — is Ansible's to match and is
recorded in the parity report, not set here.

---

## 5. Instance classes: burstable is disqualifying

**Current production**, confirmed: app server **t3.large** (2 vCPU, 8 GiB, x86), database
**db.t4g.large** (2 vCPU, 8 GiB, Graviton2). Both are burstable. **Storage on both is already gp3.**

### 5.1 Why the rig cannot use T-family

Burstable instances earn CPU credits at a fixed rate and spend them whenever utilisation exceeds a
baseline (30% per vCPU at these sizes). Three consequences, in increasing order of seriousness:

1. **A throttling cliff.** When the balance is exhausted, the instance is capped at baseline — 0.6
   vCPU-equivalent on a 2 vCPU box. Roughly a 3x drop, arriving mid-run with no warning.
2. **Unlimited mode converts the cliff into a surcharge.** Performance still varies through the
   transition, and the cost becomes a function of how hard the test pushed. Whether it is enabled
   on the current instances is worth knowing (1.1) but does not rescue the rig either way.
3. **The starting credit balance differs between runs.** A run on Monday morning after an idle
   weekend starts with a full balance; the same run repeated that afternoon starts depleted. Same
   workload, same code, different numbers.

The third is the disqualifying one. Run-to-run comparability is the single property this rig exists
to provide, and burstable instances remove it by construction.

### 5.2 Storage is already fine

An earlier draft of this section flagged EBS burst credits as a second, independent source of
non-determinism. **That does not apply — both the app server and the database already run gp3**,
which has no credit bucket: baseline 3000 IOPS and 125 MiB/s independent of volume size,
provisionable well above that. The `storage_type = "gp2"` in `provision/server/variables.tf:47` is
simply more of the same stale drift as the rest of that directory.

So CPU credits are the only credit system in play, and the fix is confined to instance class. Two
things still carry over: use gp3 in the rig (parity, and it is the right choice anyway), and treat
provisioned IOPS as a **per-phase** setting — raised for the bulk-load window, lowered for steady
state (5.7).

### 5.3 Candidate replacements, with ap-south-1 on-demand pricing

Verified against two independent sources that agree (see 5.6). Linux, on-demand, ap-south-1.

| Role | Instance | vCPU / RAM | On-demand $/hr | Spot $/hr *(reference only)* | vs t3.large |
|---|---|---|--:|--:|--:|
| App (current) | t3.large — *burstable x86* | 2 / 8 GiB | 0.0896 | 0.0306 | — |
| App | **m6g.large** — Graviton2, fixed | 2 / 8 GiB | **0.0506** | 0.0213 | **-44%** |
| App | **m7g.large** — Graviton3, fixed | 2 / 8 GiB | **0.0583** | 0.0302 | **-35%** |
| App | m5.large — Intel, fixed | 2 / 8 GiB | 0.1010 | — | +13% |
| App | m6i.large — Intel, fixed | 2 / 8 GiB | 0.1010 | 0.0342 | +13% |
| App | m7i.large — Intel, fixed | 2 / 8 GiB | 0.1061 | 0.0407 | +18% |
| App | *(rejected)* c6i.large | 2 / 4 GiB | — | — | Cannot hold prod's ~5 GiB heap |

**The headline: moving off burstable is a cost reduction, not a premium — if you go Graviton.**
m6g.large is fixed-performance *and* 44% cheaper per hour than the t3.large production runs today.
Staying on x86 for closer prod fidelity costs 13-18% more instead. Either way the absolute
difference is cents per hour, which §5.6 puts in perspective.

**Database.** The equivalent move is db.t4g.large → **db.m6g.large** (or db.m7g.large), staying on
Graviton so burstability is the only variable removed. **ap-south-1 RDS rates could not be verified
from public sources** — third-party pages consistently returned us-east-1 or us-west-2 defaults
regardless of the region requested. What is clear from those non-Mumbai anchors is that the
direction reverses for RDS: the fixed-performance M-family runs roughly 20-25% *above* the
burstable T-family, where on EC2 it runs below. **Get the actual ap-south-1 figures from the AWS
Pricing Calculator or `aws pricing get-products` once the CLI is installed (0.1), before 1.8.**

`db.r6g.large` (2 vCPU / **16 GiB**) is also worth pricing, for the reason in 5.5.

### 5.4 Recommendation

**Keep production's 2 vCPU / 8 GiB shape and move to fixed-performance silicon.**

- **App server: m6g.large.** Cheapest of the fixed-performance options, 44% below the current
  t3.large, and the same Graviton family the database already runs. m7g.large if headroom is wanted
  for 15% more. Whether a Graviton2 core sustains what a bursting t3.large does is a question for
  the first calibration run, not an assumption to bank.
- **Database: db.m6g.large**, same architecture as the current db.t4g.large.
- **Injector: on-demand**, sized for CPU and network. Spot is rejected — see 5.7.

**On the architecture change.** Moving the app server from x86 to ARM weakens app-server
extrapolation to production, which the framing above accepts as a nice-to-have. It is also less of
a leap than it sounds: the production *database* is already Graviton, and the Ansible tree already
handles arm64 images elsewhere (`configure/group_vars/metabase_docker_vars.yml:5`). **This has been
checked and there is no blocker — see §9.** If a smoke test nonetheless finds one, m6i.large at +13%
is the fallback and nothing else in the plan changes.

One observation to carry in: prod's app server runs `-Xmx5120m` with 512m metaspace on an 8 GiB box
that also runs nginx and the New Relic agent. That is tight. If runs show the app server
memory-constrained rather than CPU-constrained, moving the rig to 16 GiB is legitimate — but then
it is a deliberate deviation, recorded as such, not a default.

### 5.4a Graviton compatibility: checked, no blocker

Verified against the code rather than assumed, since 5.4 depends on it:

- **avni-server's dependencies are entirely pure Java** — Spring Boot, Postgres JDBC, Flyway, POI,
  Jackson, Guava, Keycloak, AWS SDK v1, libphonenumber, ehcache, joda-time, httpclient5. Tika is
  pulled in as `tika-core` with `tika-parsers` explicitly excluded, which is where optional native
  components would otherwise arrive. `avni-etl` is equally clean.
- **GraalVM JS does not ship in the server jar.** `org.graalvm.js:js` and `graal-sdk` belong to
  `avni-rule-server`, a separate Gradle subproject with its own `Main-Class`
  (`org.avni.ruleServer.Main`); `avni-server-api`'s bootJar is `org.avni.Avni` and carries no
  dependency edge to it.
- **The JDK is installed from apt** (`roles/jdk/tasks/java_install.yml`), and both `openjdk-21-jdk`
  and `openjdk-17-jdk` are available for arm64 in Ubuntu.
- **The New Relic agent is architecture-neutral** — a zip of Java jars, no architecture in the
  download URL (`roles/newrelic/tasks/setup_application.yml`).
- **The one arch-pinned artifact is dead code.** `roles/openjdk-18/tasks/main.yml` hardcodes
  `openjdk-18_linux-x64_bin.tar.gz`, but the role is commented out at `site.yml:34` and used by no
  playbook. It is absent from the prod avni-server role list. Only a problem if revived.
- **Precedent exists**: `roles/minio/vars/main.yml` already carries an arch map including
  `aarch64: arm64`, and production's database is itself Graviton.

Remaining action is a smoke test on one arm64 host before the module commits to it — cheap, and the
only thing that turns this from a code review into evidence.

### 5.5 Where "close enough" stops being close enough

The framing that an exact production match is a nice-to-have holds well for the **app server and
the injector**: they can be sized for cost and consistency, because what matters is that they are
fixed and identical between runs.

It holds **less well for the database**, and this is the one place to spend deliberately. The ratio
of buffer cache to working-set size decides whether a given query is served from memory or from
disk — and that decides *which* bottleneck surfaces first. Shrink the database and you will find
I/O bottlenecks production does not have; oversize it and you will miss ones it does. Since the
stated goal of the exercise is finding choke points, the database's memory should be chosen against
the dataset size, in step with whoever owns the generator, rather than treated as a cost lever.
That is what makes `db.r6g.large` worth pricing rather than dismissing.

### 5.6 Cost, in perspective

EC2 figures above are from [aws-pricing.com](https://aws-pricing.com/ap-south-1.html) and
[DoiT Compute](https://www.doit.com/compute/spot/ap-south-1/m6g.large), which agree to the cent on
every instance checked. RDS ap-south-1 remains outstanding (5.3). gp3 is unchanged from production,
so no storage price delta applies.

**The instance-class choice is not where this environment's cost is decided.** The whole app-server
spread — t3.large to m7i.large — is under six cents an hour. For an environment that runs a few
hours a week, uptime dominates: running six hours a week rather than continuously is a saving of
well over 90%, which is worth more than every instance-class decision in this section combined.

**Buy determinism on the instance class; save on the hours.** And in the Graviton case you are not
even buying it — you are being paid to take it.

### 5.7 Other levers

| Lever | Effect | Caution |
|---|---|---|
| **Destroy or stop between runs** | The dominant saving | A **stopped RDS instance restarts automatically after 7 days**. For gaps longer than that, snapshot and destroy rather than stop |
| ~~Spot for the injector~~ | **Rejected** | See below — the saving is cents, the failure mode is a lost or misleading run |
| **NAT Gateway** | An always-on hourly charge plus per-GB processing | On a mostly-idle environment this can exceed the app server's cost. Consider a free S3 gateway endpoint plus interface endpoints, a small NAT instance, or NAT present only during deploy windows |
| **Single-AZ RDS** | Roughly halves database cost | Multi-AZ changes commit latency through synchronous replication. If write-path testing matters this is a fidelity decision, not just a cost one — settle it against what prod runs (1.1) |
| **Read replica off by default** | Avoids doubling database cost | Turn on only for runs that exercise the read path |
| **Performance Insights free tier** | 7 days retention at no cost | Sufficient for a rig |
| **gp3 IOPS tuned per phase** | Provision high for the bulk load, lower for steady state | Adjustable independently of volume size |
| **Short log retention** | Controls CloudWatch cost under heavy request logging | |
| **Snapshot hygiene** | Keep the reference snapshot, delete per-run ones | |
| **No Savings Plans or Reserved Instances** | — | Wrong instrument for an ephemeral environment. Do not commit |

**Why Spot is rejected for the injector.** The injector is the box the Gatling simulation runs on,
so a Spot reclaim during a run ends the run. An earlier draft of this plan waved that away as
"costs a rerun, not a result". That was wrong on both halves:

- **It can produce a result.** Gatling writes `simulation.log` continuously. A reclaimed instance
  leaves a truncated log that still parses, and a run that stopped at minute 47 because AWS took the
  injector back looks a great deal like a run that stopped at minute 47 because the server fell
  over. That is a wrong answer, not a missing one — the worst failure mode available to a
  measurement rig.
- **The rerun is not cheap either.** Per-run setup is a database restore, a cache-warm policy and a
  statistics reset, and the soak profile runs for hours. Losing one costs the whole cycle, not the
  injector's hours.

Against that, the saving is a few cents an hour on the cheapest instance in the environment — and
Spot capacity for a given type and AZ can simply be unavailable when someone wants to start a run,
which turns a cost optimisation into a scheduling dependency.

If Spot is ever wanted, the only defensible place is a short smoke run whose result nobody relies
on. It is not worth a variable in the module; the option is recorded here so it is not
reintroduced as an optimisation later.


---

## 6. Database platform: settled upstream

**No longer an open decision.** G4 of the simulation plan now specifies it, and the answer matches
what this plan had recommended: **RDS PostgreSQL 16.8**, with

- **`CREATE DATABASE … TEMPLATE` for the per-run reset** — a file-level copy inside the existing
  instance, so no new endpoint and no lazy-loading penalty, using `STRATEGY = FILE_COPY` because
  PG15+ defaults to `WAL_LOG`, which is slow for a large template;
- **RDS snapshot restore for baseline creation and dataset portability only**, never per run.

Postgres-on-EC2 and Aurora are off the table. The consequences that land on this plan:

**Storage must hold roughly two copies of the dataset.** The pristine `avni_perf_template` database
and the per-run working copy live on the same instance, on top of the bulk-load headroom (indexes
and WAL) already noted. This is now the largest single input to `db_allocated_storage`.

**The baseline snapshot must survive `tofu destroy`.** It is a *manual* RDS snapshot, deliberately
not an automated backup, because automated backups expire with the retention window and the dataset
costs days to generate. Two consequences, both easy to get wrong:

- The module must not be able to delete it. It is created by the harness's baseline procedure rather
  than by OpenTofu, so it stays outside the module's management and outside anything `destroy`
  sweeps. Tag it against deletion, and confirm a full destroy-and-rebuild cycle (3.2) leaves it
  intact — **test that deliberately, because discovering otherwise costs days, not minutes.**
- `restore_from_snapshot` is exactly the right rebuild path and already exists as a variable. It is
  what makes the environment genuinely disposable: destroy freely, rebuild from the baseline.

**Parameter group parity is a named requirement**, autovacuum and gp3 IOPS/throughput included, and
a restored instance inherits the snapshot's group. This reinforces §5.4's recommendation to keep
production's 8 GiB: `shared_buffers`, `work_mem` and `effective_cache_size` tuned for a
db.t4g.large carry over to a db.m6g.large unchanged, where a different memory size would make the
"matching parameter group" requirement quietly untrue.

**`pg_prewarm` should be available.** G4 requires pre-warming after any snapshot restore, so confirm
the extension is usable rather than discovering it is not mid-rebuild.

**Load-event sizing still applies** — base data, indexes, WAL during bulk load, run growth, and now
the template copy. Raise gp3 provisioned IOPS for the load window and lower it after (5.7). The
loader instance inside the VPC, created and destroyed around the load, remains part of the module.

---

## 7. Module shape

```
provision/tofu/
  modules/avni-env/
    network.tf         # VPC, subnets, routing, NAT / VPC endpoints
    compute.tf         # app, etl, optional loader, optional injector
    database.tf        # RDS primary, optional replica, parameter group
    storage.tf         # media bucket (optional)
    loadbalancer.tf    # ALB, target groups, listeners, ACM
    dns.tf             # private or public zone
    access.tf          # Instance Connect Endpoint / SSM
    observability.tf   # Performance Insights, CloudWatch, log groups
    auth.tf            # optional Cognito pool
    variables.tf outputs.tf parity.tf
  envs/loadtest/
```

**Variables** — AWS-level only: `app_instance_class`, `etl_instance_class`, `db_instance_class`,
`db_storage_type`, `db_allocated_storage`, `db_iops`, `db_multi_az`, `enable_read_replica`,
`db_max_connections`, `db_autovacuum`, `enable_media_bucket`, `enable_cognito`, `enable_injector`,
`injector_instance_class`, `enable_loader`, `restore_from_snapshot`, `log_retention_days`,
`retain_on_destroy`.

**Outputs:** base URL, instance IDs, DB endpoints, reference snapshot identifier, parity report.

**The parity report** satisfies F5.2 and is committed with each apply. It records the AWS facts —
instance classes **and explicitly that they are fixed-performance where production is burstable**,
Postgres version, every parameter-group deviation, storage type and IOPS, Multi-AZ, replica present
or not, and injector network position — and leaves a slot for the application-side
values Ansible sets, so one document describes the whole environment.

---

## 8. Task breakdown

### Phase 0 — Foundations

- [ ] **0.1** Install OpenTofu and the AWS CLI. Neither is present on the workstation today.
- [ ] **0.2** Create `provision/tofu/`; pin `required_version` and an AWS provider major; commit the lock file.
- [ ] **0.3** New S3 state key, separate from `provision/server/`'s. Versioning, SSE-KMS, block-public-access, TLS-only policy.
- [ ] **0.4** State locking — DynamoDB table, or S3-native lockfile if the pinned version supports it. The existing backend config has none.
- [ ] **0.5** State **and plan** encryption via `aws_kms`, `enforced = true` on both.
- [ ] **0.6** An apply role scoped to this environment, not account-wide admin.

### Phase 1 — Decisions that change what gets built

- [ ] **1.1** Confirm from the console what §5 could not: production's volume size and provisioned IOPS, Multi-AZ or not, whether T-unlimited is enabled, and the ETL host's class.
- [ ] **1.2** Isolation posture: Instance Connect Endpoint vs SSM; NAT vs VPC endpoints; private hosted zone vs instance-ID addressing. Include NAT's standing cost (5.7) in the choice.
- [ ] **1.3** Media bucket in scope? Follows D5.
- [ ] **1.4** DNS name and zone.
- [ ] **1.5** Monthly cost ceiling, and what happens when it is hit.
- [ ] **1.6** **Follow through on §6.** The platform is settled; get the expected dataset size from the generator's owner, size storage for **two copies plus load headroom**, and time a `STRATEGY = FILE_COPY` template copy at that size so run turnaround is known.
- [ ] **1.7** Injector network position, and whether the module creates it.
- [ ] **1.8** **Pick the instance classes per §5.** EC2 pricing is settled; **fetch ap-south-1 RDS rates** for db.t4g.large, db.m6g.large, db.m7g.large and db.r6g.large, which 5.3 could not verify. Decide the app-server architecture question (x86 for extrapolation vs Graviton for cost and determinism) and record it.
- [ ] **1.9** Size the database's memory against the dataset, with the generator's owner (5.5). §6's parameter-group constraint argues for keeping production's 8 GiB unless there is a reason not to.

### Phase 2 — Build the module

- [ ] **2.1** Network — VPC, two private subnets across AZs, routing, NAT or VPC endpoints.
- [ ] **2.2** Access path — Instance Connect Endpoint or SSM, plus the instance role. **Prove a human can reach a bare instance through it before anything is built on top.** The task most likely to consume an unexpected day.
- [ ] **2.3** Compute — app and ETL instances on the fixed-performance classes from 1.8, instance profile, no static keys, Ubuntu AMI resolved via SSM parameter rather than a hardcoded ID. **Match the AMI architecture to the instance family** — an arm64 AMI for Graviton.
- [ ] **2.4** Database per 1.6 and 1.8 — `manage_master_user_password`, encryption, **gp3**, parameter group carrying `pg_stat_statements`, slow-query logging and autovacuum setting; Performance Insights and Enhanced Monitoring on; storage sized per §6.
- [ ] **2.5** Load balancer — ALB, target group, health check on `/ping`, **400s idle timeout**, ACM certificate.
- [ ] **2.6** Storage — media bucket behind `enable_media_bucket`, no replication, lifecycle expiry.
- [ ] **2.7** DNS.
- [ ] **2.8** Observability resources — log groups with `log_retention_days`, metrics, budget alarm from 1.5, cost tags. Include `CPUCreditBalance` and `BurstBalance` alarms **if any burstable resource survives into the final design**, as a guard against silently reintroducing the problem.
- [ ] **2.9** Optional loader and injector instances, both on-demand (5.7).
- [ ] **2.10** Egress restrictions and an instance role with no SNS or integration-endpoint access, so outbound side effects are impossible regardless of application config (F5.3).
- [ ] **2.11** Parity report output.

### Phase 3 — First environment

- [ ] **3.1** Apply `envs/loadtest/` with `enable_cognito = true`.
- [ ] **3.2** **Prove `tofu destroy` works, then reapply from scratch**, before anyone depends on the environment. A rig that cannot be rebuilt is not disposable, and the failure mode surfaces at the worst moment otherwise.
- [ ] **3.3** Verify the AWS layer standalone: instances reachable via the access path, database reachable from them, ALB healthy, metrics flowing, egress restricted as intended.
- [ ] **3.4** Hand off to Ansible — see §9.

### Phase 4 — Rig operations

- [ ] **4.1** Implement the restore mechanism chosen in 1.6, and time it. Restore duration sets the floor on run turnaround.
- [ ] **4.2** Expose reference-snapshot capture and restore as repeatable operations the harness can invoke.
- [ ] **4.3** Documented resize procedure — change a variable, apply, record the parity report. This is the mechanism by which the rig answers "at what size does it stop breaking".
- [ ] **4.4** Scheduled stop or destroy outside working hours, **with an override guard** so multi-hour runs are not torn down mid-run. Prefer snapshot-and-destroy over stop for gaps beyond a week (5.7).
- [ ] **4.5** Loader instance lifecycle — created for the load, destroyed after.

### Phase 5 — Close the environment

Gated on the harness's B2 → F4 → B1 ordering; triggered by that plan's owner, not this one.

- [ ] **5.1** Set `enable_cognito = false` and apply.
- [ ] **5.2** Remove any remaining public path.
- [ ] **5.3** Re-verify the deploy access path works closed.
- [ ] **5.4** Confirm the injector can still reach the environment.

### Phase 6 — Generalise

- [ ] **6.1** Second instantiation at different sizing, to prove the variables work. A module used once is parameterised, not reusable.
- [ ] **6.2** Extract environment-specific values into `tfvars`.
- [ ] **6.3** Publish endpoints and generated secrets to SSM / Secrets Manager for Ansible to read at run time.
- [ ] **6.4** CI: plan on PR, no auto-apply, no plan bodies in logs.

---

## 9. Environment configuration (Ansible)

Half the delivery, and the half most likely to be underestimated — the OpenTofu is ordinary AWS
work, whereas this part has no existing template to copy from.

### 9.1 What exists today: the `PERF_deploy` job is miswired

Earlier drafts of this plan recorded "no load-test Ansible configuration exists, and a `PERF_deploy`
job calls something that is not in this repository" as an open unknown. **It has been traced, and
the finding is worse than a missing file.**

`avni-server/.circleci/config.yml` defines `PERF_deploy` (line 215) and `PRERELEASE_deploy`
(line 201). Both call the same command with the same argument — `deploy_as_service` with
`env: "prerelease"` — which downloads `avni-infra` master and runs
`make deploy-avni-server-prerelease`. That target is pinned to `-i inventory/prerelease`, whose
`[avniservers]` group is `ssh.prerelease.avniproject.org` (`configure/Makefile:334-336`).

The only difference between the two jobs is the instance passed to `setup_server_access`:
`i-0f30399b30e24a49b` for PERF, `i-0cdce9ae698eb3462` for PRERELEASE. That step does nothing but
push a 60-second EC2 Instance Connect key to that instance — **it does not change the Ansible
inventory host.**

So `PERF_deploy` authorises a key on the perf instance and then deploys to the prerelease host. It
has never configured a perf environment. Two things follow:

- **There is no perf Ansible configuration to find, recover or adapt.** Everything in 9.2 is new
  work, not archaeology.
- **Had it worked, it would have been wrong anyway.** It passes
  `deploy_app_env_vars_file: group_vars/prerelease_vars.yml`, so the perf server would have been
  configured against prerelease's database — violating B1's requirement that the environment never
  share a database with anything real.

**Action:** fix or delete `PERF_deploy` in avni-server. Leaving a job that silently deploys to the
wrong host is worse than having none, and it will collide with the new target below.

### 9.2 Build the environment configuration

- [ ] **9.1** `inventory/loadtest`. **This is the genuinely new pattern.** Every existing inventory
      addresses hosts by public DNS name; a private environment with no public IP cannot. The
      inventory must connect through the Instance Connect Endpoint or SSM tunnel, via
      `ansible_ssh_common_args` with a `ProxyCommand`, addressing hosts by instance ID. Note the
      existing `setup_server_access` pattern is *not* this — it pushes a key by instance ID and then
      connects by DNS, which is exactly why it cannot reach a private host.
- [ ] **9.2** `loadtest_avni_servers.yml` and `loadtest_etl_servers.yml`, modelled on the prod
      playbooks.
- [ ] **9.3** `group_vars/loadtest_vars.yml` and its secret-vars counterpart. **Nothing shared with
      any real environment** — own database endpoint, own bucket, own credentials.
- [ ] **9.4** Makefile targets. **Copy an existing avni-server target verbatim** rather than writing
      one: `java_apt_package: openjdk-21-jdk` is passed per-target via `--extra-vars`
      (`Makefile:74,78,82`, `328-344`) and not held in `group_vars`, so a fresh target silently
      falls through to `basic_vars.yml:28`'s `openjdk-8-jdk` and avni-server dies at first start
      with `UnsupportedClassVersionError` — which reads like a build failure, not a missing
      variable. `rwb-staging` and `rwb-prod` (89,93) already omit it, so the trap is live.
- [ ] **9.5** `avni_server_idp_type: none` (B1). The template already passes it through
      (`roles/avni_appserver/templates/appserver.conf.j2:37`), so this is a variable value, not a
      role change. It must land in step with the Phase 6 close, never before.
- [ ] **9.6** **Set the connection pool size explicitly** (harness requirement I2). It is currently
      unconfigured and sitting at the Tomcat JDBC default, which the harness predicts is itself the
      first choke point — so it has to be a knob rather than an accident. No application change is
      needed: `start.sh` passes `avni_server_opts` straight to `java`, so
      `-Dspring.datasource.tomcat.max-active=N` in the loadtest vars is sufficient.
- [ ] **9.7** Log level chosen deliberately (I2), by the same `-D` route, and recorded in the parity
      report.
- [ ] **9.8** JVM heap set to match production's `-Xms2560m -Xmx5120m`, or deliberately not, and
      recorded either way.
- [ ] **9.9** **Suppress outbound side effects in configuration as well as at the boundary** — no
      Glific, SMS or integration credentials in the loadtest secret vars. §8's IAM and egress
      restrictions are the backstop; this is the first line.
- [ ] **9.10** Decide whether the `newrelic` role runs here. It is the shortest path to the JVM and
      GC metrics F1 wants and matches production, but it is licensed per host; a JMX exporter is the
      alternative.
- [ ] **9.11** `security` role `ufw_allowed_ports` for this environment — the ALB's target port and
      the injector's path, and nothing else.
- [ ] **9.12** Feed the application-side values into the parity report so one document describes the
      whole environment.
- [ ] **9.13** Run it end to end and confirm the service starts, serves `/ping` through the ALB, and
      reaches its own database and nothing else.

---

## 10. Owned by the harness

`avni-perf` owns dataset generation and load, user provisioning, per-run restore and statistics
reset, and injector operation. Dataset size is an input this plan needs (1.6, 1.9); its section I is
the authoritative statement of what the environment must provide (§3).

---

## 11. Risks

| Risk | Mitigation |
|---|---|
| **Burstable classes reintroduced by copying production** | §5; 2.8's credit-balance alarms catch it if it happens anyway |
| gp3 IOPS left at baseline and the bulk load is throttled | 5.7 — IOPS raised for the load window, lowered after |
| Database under-sized relative to dataset, changing which bottleneck appears | 1.9 sizes DB memory against the dataset with the generator's owner |
| Baseline snapshot destroyed with the environment, losing days of dataset generation | §6 — snapshot kept outside module management; 3.2 verifies a destroy/rebuild cycle leaves it intact |
| Storage sized for one copy of the dataset, so the per-run template copy has nowhere to go | §6; 1.6 sizes for two copies plus load headroom |
| Bulk load takes days because storage was sized for steady state | §6; gp3 IOPS raised for the load window |
| Load-test make target written fresh and omits `java_apt_package` | 9.4 — copy an existing target; the failure looks like a build error, not a config one |
| Private networking becomes a multi-day yak shave | 2.2 proves the access path standalone, early |
| First Ansible run fails on egress | NAT/VPC-endpoint decision in 1.2, not discovered at handoff |
| A run emits real SMS or hits a real integration | 2.10 — enforced at IAM and egress, not app config |
| NAT Gateway quietly becomes the largest line on a mostly-idle environment | 1.2 costs it explicitly against endpoint alternatives |
| Scheduled teardown kills a long run | 4.4's override guard |
| Environment left running between runs | Budget alarm, scheduled destroy, cost tags (2.8, 4.4) |
| `destroy` fails on a dependent resource; environment becomes semi-permanent | 3.2 tests destroy while nothing depends on it |
| `PERF_deploy` keeps deploying to the prerelease host, or collides with the new target | 9.1 — fix or delete it in avni-server before the new target exists |
| Module ossifies around load testing and fits customer environments badly | 6.1 forces a differently-shaped second instantiation |

---

## 12. Sizing

| Phase | Size | Notes |
|---|---|---|
| 0 — Foundations | ~1 day | KMS and backend |
| 1 — Decisions | 1–2 days | 1.6 and 1.9 need a dataset-size input |
| 2 — Build module | 4–6 days | 2.2 and 2.4 dominate |
| 3 — First environment | 1–2 days | AWS layer only |
| 9 — Ansible configuration | **3–5 days** | No existing template for private-host addressing (9.1) |
| 4 — Rig operations | 1–2 days | |
| 5 — Close | ~1 day | Scheduled by the harness owner |
| 6 — Generalise | 2–3 days | Deferrable until a second consumer is real |

---

## 13. Definition of done

- The environment exists, is deployable to without public ingress, and can be reached by the injector.
- **avni-server and avni-etl are deployed and running on it from `configure/`**, on Java 21, with the connection pool size set explicitly and no route to any real database or third party.
- **No component under test is burstable, and storage is gp3** — two runs of the same workload on
  the same infrastructure produce comparable numbers.
- It can be destroyed and rebuilt from scratch, demonstrated at least once.
- RDS-side metrics are live and resettable; log retention is set.
- The database can be restored to a reference state at a measured, acceptable turnaround.
- Sizing is variable-driven, and each apply emits a parity report.
- State and plan files are encrypted, locked, and hold no secret values.
- Spend is tagged, capped by an alarm, and the environment is off when not in use.
