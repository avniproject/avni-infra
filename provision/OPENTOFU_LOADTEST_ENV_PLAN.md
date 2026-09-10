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

`avni-perf/docs/sync-simulation-plan.md` gathers these itself, in **section J — "What the harness
requires of the environment"** (formerly section I; I is now multi-tenancy), with each item traced to
the task that produced it. That is the authoritative list; it is not restated here. Its subsections
are still labelled I1–I5.

- **I1** network and access — no public reachability, Instance Connect Endpoint or SSM, instance-ID
  addressing, an outbound path for deploy-time package fetches, deliberate DNS, a position for the
  injector.
- **I2** application configuration — Ansible's, per §2.
- **I3** database — PostgreSQL 16.8, dedicated, production-matched parameter group and storage
  class, `pg_stat_statements` and slow query logging, **storage autoscaling disabled**, storage
  headroom **conditional on the reset mechanism** (2× for `TEMPLATE`, ~1× otherwise — undecided), and
  snapshot/restore for baseline creation rather than per-run reset.
- **I4** data and side effects — including an **outbound path for run artefacts**, and the finding
  that a real media bucket is probably unnecessary (D5.4).
- **I5** observability — all of F1 restated, and it names the missing loadtest `group_vars` file as
  the blocker, which is §9's 9.3.

**That section deliberately excludes sizing** — instance classes, storage sizes, pool values and
heap settings. Those are this plan's (§5) and Ansible's. The division is clean and worth preserving:
the harness states what must be true, this plan decides how large.

---

## 4. What "production-shaped" means at the AWS layer

| Dimension | Reference | Why it matters |
|---|---|---|
| Topology | VPC, two subnets across AZs, app host, RDS primary **+ read replica**, S3 media, load balancer | The replica exists in prod (`configure/group_vars/prod_vars.yml:48`); omitting it changes read-path behaviour |
| Host separation | avni-server and avni-etl on **separate instances** | Prod runs them apart (`configure/inventory/prod`); co-locating changes CPU and connection contention |
| Instance classes | See §5 — **deliberately not matched** | Production is burstable (app `t3.large`, ETL `t3.small`, DB `db.t4g.large`); the rig cannot be |
| Availability | **Single-AZ**, as production is | Multi-AZ would add synchronous-standby commit latency production does not have |
| Postgres version | **16.8**, matching production exactly (J/I3) | Planner behaviour is version-specific |
| Storage | gp3 throughout. Production: app server **40 GB**, RDS **300 GB allocated / ~122 GB used**, both at 3000 IOPS / 125 MiB/s | **I/O parity is required** (J/I3), which caps the rig below 400 GiB — see §6 |
| LB idle timeout | 400s | `provision/server/elb.tf`. Sync requests are long; a shorter timeout converts slow responses into errors |

**Deliberately not copied from the old Terraform:** `ami-531a4c3c`/Amazon Linux → Ubuntu;
`aws_elb` Classic → ALB; `storage_encrypted = false` → encrypted; `password = "password"` →
`manage_master_user_password`; static IAM user access keys → instance profile only; public subnet
with `0.0.0.0/0` SSH → private, no public ingress; Makefile workspace juggling with `_override.tf` →
one state per environment with plain `tfvars`.

**Application-level parity** — JVM flags, pool size, log level — is Ansible's to match and is
recorded in the parity report, not set here.

---

## 5. Instance classes and sizing

**Current production**, confirmed: app server **t3.large** (2 vCPU, 8 GiB, x86), database
**db.t4g.large** (2 vCPU, 8 GiB, Graviton2). Both are burstable. **Storage on both is already gp3.**

### 5.1 Burstable: the case is cost, not determinism

**Production runs T-unlimited**, which overturns this section's original argument.

An earlier version of this plan held that burstable instances disqualify themselves twice over:
credit exhaustion throttles to a 0.6 vCPU baseline, and a differing starting credit balance makes
two runs of the same workload incomparable — the latter described as "the disqualifying one".
**Neither holds in unlimited mode.** The EC2 documentation is explicit that an instance configured
as `unlimited` *"can sustain high CPU utilization for any period of time whenever required"*. There
is no throttling and no dependence of performance on the credit balance. The consequence of
exhausting credits is a charge, not a slowdown.

What survives is narrower, and still points the same way:

- **Cost, and it inverts under precisely this workload.** Surplus credits are charged at a flat rate
  per vCPU-hour once the 24-hour rolling average exceeds baseline — and a load test is exactly the
  sustained-high-CPU workload that maximises that charge. A `t3.large` held near 100% runs ~1.4
  surplus vCPU-hours per hour above its 0.6 vCPU baseline; at the published T3 unlimited rate that
  is roughly \$0.07/hr on top of the \$0.0896 base — call it ~\$0.16/hr against `m6g.large`'s flat
  \$0.0506. **Confirm the ap-south-1 surplus rate in 1.8**; the estimate is directional.
- **A bill that varies with how hard each test pushed.** An operational annoyance rather than a
  correctness problem, but one more thing to reconcile when comparing runs.
- **Fidelity, which now argues mildly *for* the change.** Because production runs unlimited, it
  effectively delivers its full 2 vCPUs under sustained load. A fixed-performance 2 vCPU / 8 GiB
  instance is therefore a clean parity match for how production behaves when busy, with no
  baseline-versus-burst distinction to reason about at all.

**Net: the recommendation in 5.4 is unchanged, but it rests on cost and simplicity rather than on
determinism.** Had production been running standard mode, the original argument would have held and
the case would have been considerably stronger. It is worth recording that it does not, so nobody
rebuilds the argument from the earlier draft.

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
| ETL (current) | t3.small — *burstable* | 2 / 2 GiB | 0.0224 | — | — |
| ETL | **m6g.medium** — Graviton2, fixed | 1 / 4 GiB | **0.0253** | — | +13%, doubles RAM |
| ETL | c6g.medium — Graviton2, fixed | 1 / 2 GiB | 0.0213 | — | **−5%**, same RAM |
| ETL | c6g.large — Graviton2, fixed | 2 / 4 GiB | 0.0426 | — | +90% |

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
- **ETL: m6g.medium**, if the ETL host is needed at all (see below). Production's t3.small runs a
  ~1.6 GiB JVM (`-Xms1228m -Xmx1228m` plus metaspace) on a 2 GiB box, which is very tight; m6g.medium
  doubles the memory for three tenths of a cent an hour more, and its 1 fixed vCPU still exceeds the
  0.4 vCPU sustained baseline a t3.small actually delivers. c6g.medium is *cheaper* than the
  burstable t3.small if the 2 GiB is kept.
- **Injector: on-demand**, sized for CPU and network. Spot is rejected — see 5.7.

**The ETL host is required, and this reverses an earlier assumption in this plan.** F5.3 no longer
treats background jobs as housekeeping: `avni-etl` runs on a **90-minute Quartz cycle**, reads the
public schema in direct competition with sync, and shares the same fixed 3,000 IOPS. An ETL cycle
landing on the start-of-day sync herd is a *scheduled, recurring production event*, so the harness
now wants **two scenarios — sync alone, and sync with a concurrent ETL cycle — with the delta treated
as a finding.** Suppressing ETL would hide one of the more plausible real-world contention sources.

`enable_etl` therefore stays as a variable, because running both scenarios requires turning it on and
off — but it **defaults on**, and the ETL host is part of the environment rather than an optional
extra.

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
| **Single-AZ RDS** | Roughly halves database cost | **Settled: production is single-AZ**, so the rig is too. Cheaper *and* higher fidelity — Multi-AZ would add synchronous-standby commit latency production does not have |
| **Read replica off by default** | Avoids doubling database cost | Turn on only for runs that exercise the read path |
| **Performance Insights free tier** | 7 days retention at no cost | Sufficient for a rig |
| ~~gp3 IOPS tuned per phase~~ | **Not available on RDS below 400 GiB** | For RDS PostgreSQL, 20–399 GiB is a fixed 3000 IOPS / 125 MiB/s with provisioned IOPS and throughput listed as *Not applicable*. The lever is the size threshold, not a runtime setting — see §6. It *does* work on the app server's own EBS volume |
| **Short log retention** | Controls CloudWatch cost under heavy request logging | |
| **Snapshot hygiene** | Keep the reference snapshot, delete per-run ones | The baseline snapshot is **not free** — #88 records `ChargedBackupUsage` of ~\$236/month for `proddb02`, scaling with size. The rig keeps its baseline indefinitely by design, so include it in the 1.5 ceiling |
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

## 6. Database platform and the reset mechanism

**The platform is settled: RDS PostgreSQL 16.8.** G4 rules out every alternative — `pg_basebackup`,
EBS/ZFS snapshots and Database Lab Engine all need filesystem access, so using them would mean the
perf database is no longer RDS, *"trading away production parity, which is a worse loss than a slow
reset"*. Aurora fast cloning is the right tool for the problem and is unavailable for the same
reason. **This retires the Postgres-on-EC2 fallback this plan previously carried.**

**The per-run reset mechanism is now decided, and decided on parity grounds.** G4 rules out
`CREATE DATABASE … TEMPLATE`: it needs 2x the dataset, and doubling crosses the 400 GiB striping
threshold, which would hand the rig 12,000 IOPS against production's 3,000 — *"not merely expensive
here, it breaks IO parity as a side effect."* The choice is **`pg_dump`/`pg_restore --jobs` or
regenerating from the generator's bulk `COPY`**, both of which keep allocated storage near 1x and
stay under the ceiling. Reset time is no longer the deciding factor, only something to measure so
run turnaround is known.

| Mechanism | Peak storage | Status |
|---|---|---|
| `pg_dump` / `pg_restore --jobs` | ~1x, artefact in S3 | **Chosen** — decide between these two on measured time |
| Regenerate from bulk `COPY` | ~1x, no artefact | **Chosen** — same |
| `CREATE DATABASE … TEMPLATE` | 2x | Rejected — breaks I/O parity via the striping threshold |

RDS snapshot restore remains right for baseline creation and dataset portability, and wrong per run.

> **Worth confirming before sizing.** G4's rejection of `TEMPLATE` reasons from production's **300 GiB
> allocated**, doubling to ~600 GiB. But #88 records `proddb02` at **~122 GB actually used**, and G4
> itself says the generated dataset should be sized against the *transactional* portion — smaller
> again, since per-organisation ETL schemas plausibly exceed half of it. At ~122 GB, 2x is ~244 GB and
> stays comfortably under 400 GiB, so `TEMPLATE` would not break parity and would give much faster
> resets. **Raise this with the harness owner**: if the dataset lands near the used figure rather than
> the allocated one, the rejection may not hold. The plan proceeds at 1x either way, which is the safe
> direction — 1x forecloses nothing, and RDS storage only ever grows.

**Why this lands on infrastructure rather than on the harness.** Two RDS properties make the choice
irreversible in one direction:

- **Allocated storage can only be increased, never decreased**, so any over-provisioning is a
  permanent commitment for the life of that instance.
- **Crossing 400 GiB is the parity failure**, and it can happen through sizing rather than through a
  deliberate decision.

**Size at ~1x.** With `TEMPLATE` rejected there is no doubling, so the figure follows the dataset
alone plus WAL and index headroom. If `pg_dump`/`pg_restore` is chosen, the dump artefact lives in S3
and needs a home and a lifecycle — larger and longer-lived than the run-artefacts bucket in 2.6.

The consequences that land on this plan:

**Storage: stay under 400 GiB, for I/O parity with production.**

Production reference, confirmed: app server **40 GB gp3**, RDS **300 GB gp3 allocated with ~122 GB
actually used** (issue #88, which proposes right-sizing prod to 200 GB), both at 3000 IOPS,
single-AZ.

**Decision: match production's I/O.** The harness (J/I3) requires storage class, IOPS and throughput
matching production, and that requirement wins here. Since the goal is finding choke points, giving
the rig *more* I/O than production would mask a storage bottleneck production actually has.

RDS gp3 for PostgreSQL has a hard threshold at 400 GiB:

| Storage | Baseline | Provisionable |
|---|---|---|
| 20–399 GiB | 3000 IOPS / 125 MiB/s | **Not applicable** — cannot be raised |
| 400 GiB+ | 12,000 IOPS / 500 MiB/s | 12,000–64,000 IOPS, 500–4,000 MiB/s |

Production sits in the lower tier, so **the rig must stay below 400 GiB** — and at 400 GiB+ the
*minimum* is 12,000/500, so there is no way to have the larger volume and prod's I/O together.

**Size at ~1x of the dataset, inside that ceiling.** With `TEMPLATE` rejected, allocated storage
follows the dataset plus WAL and index headroom — **150–200 GiB** at production-scale transactional
data. Note the dataset is sized against production's **transactional** portion, not the 300 GiB
allocated figure: per-organisation ETL schemas flatten every JSONB key into a column and plausibly
account for more than half of it. Confirm that split in 1.6 before fixing the number.

**What this costs, and it is not free.** Everything is bounded by 125 MiB/s:

- **The bulk load** (H4) runs at that ceiling. It happens once per environment, so it is tolerable.
- **The per-run reset is the one that matters.** `pg_restore` and regeneration both pay a full index
  rebuild — GIN worst — against 125 MiB/s. **That is the floor on run turnaround**, and 4.1 measures
  both so the number is known rather than assumed.

**Storage autoscaling must be off, explicitly.** This is the way the parity decision above gets
undone silently. RDS storage autoscaling grows the volume when free space runs low; if it grew the
rig past 400 GiB mid-campaign, the volume would restripe to **12,000 IOPS / 500 MiB/s** and every
subsequent run would sit on different storage performance than the ones before it — with nothing in
the Gatling report to show for it. That is precisely the class of silent, invalidating change this
environment exists to avoid.

In OpenTofu, autoscaling is controlled by `max_allocated_storage` on `aws_db_instance`: setting it
enables autoscaling, omitting it or setting `0` disables it. **Leave it unset, and say so in a
comment** so nobody adds it later as a well-meant safety net. Apply the same to the read replica if
`enable_read_replica` is on — replica storage can diverge from the primary's (#88 records
`proddb02-read` at 284 GB against a 300 GB primary), so it can cross the threshold independently.

**The trade this makes, deliberately:** with autoscaling off, a full volume puts the instance into
`storage-full` and it stops serving. That is a hard failure — but a *loud* one, and a loud failure is
strictly better here than a silent change in what is being measured. Alarm on `FreeStorageSpace`
(2.8) so it is caught before it happens. Note also that the working copy grows during runs that
exercise the push path, so free space moves during a campaign, not just between environments.

**The escape hatch, and its price.** If measured turnaround proves unworkable, raising I/O means
either crossing 400 GiB — which quadruples baseline I/O but forfeits parity, making every result
before and after incomparable — or moving to io1/io2, which forfeits parity differently. Treat it as a deliberate re-baselining, not a tuning knob. Note also that growing
across 400 GiB crosses the 1→4 volume striping boundary, which makes RDS migrate the data and can
take hours, so do it as a rebuild from the baseline snapshot rather than an in-place modify.

**RDS storage cannot be shrunk** (#88), only grown — so the ceiling is one-way, and a baseline
snapshot cannot be restored into anything smaller than it came from.

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
`db_max_connections`, `db_autovacuum`, `db_multi_az`, `enable_etl`, `enable_media_bucket`, `enable_cognito`, `enable_injector`,
`injector_instance_class`, `enable_loader`, `restore_from_snapshot`, `log_retention_days`,
`retain_on_destroy`.

**Outputs:** base URL, instance IDs, DB endpoints, reference snapshot identifier, parity report.

**The parity report** satisfies F5.2 and is committed with each apply. It records the AWS facts —
instance classes **and explicitly that they are fixed-performance where production is burstable**,
Postgres version, every parameter-group deviation, storage type and IOPS, Multi-AZ, replica present
or not, **that storage autoscaling is disabled**, injector network position, **whether the run had a concurrent ETL cycle** — now a
scenario dimension rather than a housekeeping note, and the delta between the two is itself a finding and **which tenancy model the run used**, shared or dedicated (section I4 — results are not
comparable across models) — and leaves a slot for the application-side
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

- [x] **1.1** ~~Confirm production's storage, IOPS, Multi-AZ, ETL host class and credit mode~~ — **answered in full: app server 40 GB gp3, RDS 300 GB gp3 (~122 GB used per #88), 3000 IOPS on both, single-AZ, ETL on t3.small, and T-unlimited is enabled** (see 5.1 — this materially weakened the original case against burstable).
- [ ] **1.2** Isolation posture: Instance Connect Endpoint vs SSM; NAT vs VPC endpoints; private hosted zone vs instance-ID addressing. Include NAT's standing cost (5.7) in the choice.
- [ ] **1.3** Media bucket — **D5.4 now answers this: probably not needed.** Presigning is local and nothing validates the bucket's existence, so the requirement is a configured `bucketName` and a populated organisation `mediaDirectory` (Ansible, 9.x), not an AWS resource. Leave `enable_media_bucket` off unless someone opts in deliberately.
- [ ] **1.4** DNS name and zone.
- [ ] **1.5** Monthly cost ceiling, and what happens when it is hit.
- [ ] **1.6** **Get the reset-mechanism decision from the harness owner before provisioning** (§6). It sets whether storage is ~1× or 2× the dataset, and RDS storage cannot be reduced afterwards. With the dataset size from the generator's owner, confirm the chosen multiple fits **below the 400 GiB I/O-parity ceiling** with load headroom. If it does not, raise it before building — it forces a choice between parity and capacity.
- [ ] **1.7** Injector network position, and whether the module creates it.
- [ ] **1.8** **Pick the instance classes per §5.** Confirm the ap-south-1 **T3/T4g unlimited surplus rate** as well, since 5.1's cost comparison depends on it. EC2 pricing is settled; **fetch ap-south-1 RDS rates** for db.t4g.large, db.m6g.large, db.m7g.large and db.r6g.large, which 5.3 could not verify. Decide the app-server architecture question (x86 for extrapolation vs Graviton for cost and determinism) and record it.
- [ ] **1.10** **Check production's I/O headroom now, before building anything.** G4 flags storage I/O as a prime suspect ahead of any test run: a 300 GiB database with GIN indexes serving page-size-1000 sync reads against a hard 3,000 IOPS / 125 MiB/s ceiling. This is answerable from production CloudWatch today — `ReadIOPS` + `WriteIOPS` against 3,000, `ReadThroughput` + `WriteThroughput` against 125 MiB/s, and `DiskQueueDepth`, where sustained non-zero queue depth is the signal that I/O is the binding constraint. **Cheap, needs no environment, and could pre-empt a large part of the exercise.**
- [ ] **1.9** Size the database's memory against the dataset, with the generator's owner (5.5). §6's parameter-group constraint argues for keeping production's 8 GiB unless there is a reason not to.

### Phase 2 — Build the module

- [ ] **2.1** Network — VPC, two private subnets across AZs, routing, NAT or VPC endpoints.
- [ ] **2.2** Access path — Instance Connect Endpoint or SSM, plus the instance role. **Prove a human can reach a bare instance through it before anything is built on top.** The task most likely to consume an unexpected day.
- [ ] **2.3** Compute — app instance on the fixed-performance class from 1.8; **ETL instance behind `enable_etl`, default on** (5.4 — the harness needs sync-with-concurrent-ETL as a scenario, so the variable exists to toggle between runs, not to omit the host); instance profile, no static keys, Ubuntu AMI resolved via SSM parameter rather than a hardcoded ID. **Match the AMI architecture to the instance family** — an arm64 AMI for Graviton.
- [ ] **2.4** Database per 1.6 and 1.8 — `manage_master_user_password`, encryption, **gp3 sized below 400 GiB** to hold production's 3000 IOPS / 125 MiB/s (§6 — crossing the threshold forfeits I/O parity), **`max_allocated_storage` left unset so storage autoscaling cannot silently cross it**, and the same on the read replica if enabled. **PostgreSQL 16.8**, **single-AZ** as production is, parameter group carrying `pg_stat_statements`, slow-query logging and the autovacuum setting, Performance Insights and Enhanced Monitoring on, `pg_prewarm` available.
- [ ] **2.5** Load balancer — ALB, target group, health check on `/ping`, **400s idle timeout**, ACM certificate.
- [ ] **2.6** Storage — a **run-artefacts bucket** (J/I4: `simulation.log`, reports and run metadata must have a way out of a closed environment), written by the injector via its instance profile and reachable through a free S3 gateway endpoint. Media bucket behind `enable_media_bucket`, default off per 1.3. No replication, lifecycle expiry on both.
- [ ] **2.7** DNS.
- [ ] **2.8** Observability resources — log groups with `log_retention_days`, metrics, budget alarm from 1.5, cost tags, and a **`FreeStorageSpace` alarm**, which matters more than usual because autoscaling is deliberately off (§6): the volume filling is a hard stop rather than a silent grow. If any burstable instance survives into the final design, alarm on **`CPUSurplusCreditsCharged`** rather than `CPUCreditBalance`: under T-unlimited the balance no longer signals a performance problem, only a cost one (5.1). `BurstBalance` does not apply at all — it is a gp2 metric and everything here is gp3.
- [ ] **2.9** Optional loader and injector instances, both on-demand (5.7).
- [ ] **2.10** Egress restrictions and an instance role with no SNS or integration-endpoint access, so outbound side effects are impossible regardless of application config (F5.3).
- [ ] **2.11** Parity report output.

### Phase 3 — First environment

- [ ] **3.1** Apply `envs/loadtest/` with `enable_cognito = true`.
- [ ] **3.2** **Prove `tofu destroy` works, then reapply from scratch**, before anyone depends on the environment. A rig that cannot be rebuilt is not disposable, and the failure mode surfaces at the worst moment otherwise.
- [ ] **3.3** Verify the AWS layer standalone: instances reachable via the access path, database reachable from them, ALB healthy, metrics flowing, egress restricted as intended.
- [ ] **3.4** Hand off to Ansible — see §9.

### Phase 4 — Rig operations

- [ ] **4.1** Implement whichever reset mechanism 1.6 settled, and **time all three candidates once** as G4 asks — the decision is meant to come from measurement, not argument. If `TEMPLATE`, pass `STRATEGY = FILE_COPY` explicitly, because PG15+ defaults to the slower `WAL_LOG`. Restore duration sets the floor on run turnaround, and at 125 MiB/s it is the price of I/O parity. **If it proves unworkable, that is the trigger to revisit §6's ceiling** — a re-baselining, not a tuning knob.
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
| **Storage autoscaling grows the volume past 400 GiB mid-campaign**, restriping to 12,000 IOPS / 500 MiB/s and silently invalidating I/O parity | §6 — `max_allocated_storage` left unset on primary and replica; `FreeStorageSpace` alarm in 2.8 |
| gp3 IOPS left at baseline and the bulk load is throttled | 5.7 — IOPS raised for the load window, lowered after |
| Database under-sized relative to dataset, changing which bottleneck appears | 1.9 sizes DB memory against the dataset with the generator's owner |
| Baseline snapshot destroyed with the environment, losing days of dataset generation | §6 — snapshot kept outside module management; 3.2 verifies a destroy/rebuild cycle leaves it intact |
| Storage sized for the wrong reset mechanism — too little for `TEMPLATE`, or 2× committed permanently when ~1× would have done | §6; 1.6 takes the reset decision *before* provisioning |
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
