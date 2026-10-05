# Resizing the load-test environment

Issue #109, task 4.3. This is how the rig answers *"at what size does it stop
breaking?"* — change a variable, apply, record the parity report.

It is also the procedure for changing the database instance class for cost
reasons, which turns out to be the same operation with a different motive and a
much worse failure mode.

---

## The short version

```bash
. provision/scripts/aws-session.sh
$EDITOR provision/tofu/envs/loadtest/terraform.tfvars      # set the variable
tofu -chdir=provision/tofu/envs/loadtest plan -out=resize.tfplan
tofu -chdir=provision/tofu/envs/loadtest show -json resize.tfplan | less   # read it
tofu -chdir=provision/tofu/envs/loadtest apply resize.tfplan
git add provision/tofu/envs/loadtest/parity-report.md && git commit
```

The parity report regenerates on every apply. **Commit it with the change**, or
the record of what the environment was when a result was produced is lost.

---

## What can be resized, and what each costs

| variable | effect | disruption |
|---|---|---|
| `db_instance_class` | database CPU/memory | **reboot**; see the whole of the next section |
| `app_instance_class` | app server CPU/memory | instance stop/start |
| `injector_instance_class` | injector CPU/memory | instance stop/start |
| `db_allocated_storage` | storage, and therefore baseline IOPS | online, but **cannot be reduced** |
| `db_max_connections` | connection ceiling | `pending-reboot` — see below |

---

## Four traps, each of which has already cost a day

### 1. The variable must be declared at the ROOT, not just in the module

`terraform.tfvars` is read by the root module. A variable the root does not
declare is **silently ignored**: `tofu plan` reports `No changes` and puts the
reason in an undeclared-variable warning several screens above the summary.

This happened with `db_instance_class` on 2026-09-30. Fixed in `99a05d4`, but the
same trap applies to any new variable. Before believing a resize did nothing,
check for:

```
Warning: Value for undeclared variable
```

### 2. The AZ may simply refuse, and this is normal

```
InsufficientDBInstanceCapacity: Cannot modify the instance class because there
are no instances of the requested class available in the current instance's
availability zone.
```

Observed four times across 2026-09-30 and 10-01, for **both** `db.m6g.large` and
`db.t4g.medium`, in `ap-south-1a`. It is not a sustained shortage — a retry
120 seconds later has succeeded every time — so treat it as a race to re-enter,
not a blocker.

`env-teardown.sh start|stop` retries this automatically since `f1e8c7f`, bounded
at ten minutes, and **only** for capacity. A `tofu apply` does not retry: re-run
the apply.

If it persists, the durable fix is to stop being pinned to one AZ. The subnet
group already spans three; the instance sits in `ap-south-1a` only because that
is where it was created, and nothing in the module sets `availability_zone`.
Moving it means a snapshot restore into another AZ — which is also the only way
to change the class of a **stopped** instance, so the two problems share one
solution.

**Considered and deliberately not done, 1 Oct 2026.** A single-AZ instance always
lives in exactly one AZ, so relocating does not remove the exposure, it moves it.
Multi-AZ would remove it but doubles the database cost and makes writes
synchronous, breaking parity with production's `MultiAZ: false`. And a snapshot
restore lazy-loads from S3, so the instance has markedly worse IO until every
block has faulted in — the environment would produce quietly wrong numbers until
warmed, which is why G4 reserves snapshots for baseline creation rather than
routine use. The retry in `env-teardown.sh` has cleared every occurrence on the
first attempt. **Do this opportunistically at the next destroy and rebuild**,
where a fresh instance is being created and the data reloaded anyway, rather than
as a task of its own.

### 3. A stopped instance cannot have its class changed at all

`ModifyDBInstance` requires the instance to be available. So the sequence is
start → modify → (reboot) → stop, not modify-while-stopped. Budget for the
instance being up during the change.

### 4. `static` parameters need a reboot, and a start is not a reboot

`max_connections` is `apply_method = "pending-reboot"`. On 2026-10-01 the
environment was started after the parameter changed and came up **still on the
old value** — RDS applied it only in a separate reboot afterwards. Verify rather
than assume:

```sql
select name, setting, pending_restart from pg_settings where name = 'max_connections';
```

`pending_restart = t` means it has not taken effect yet.

```bash
aws rds describe-db-instances --db-instance-identifier avni-loadtest \
  --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus'
```

`in-sync` is the state you want; `pending-reboot` is not.

---

## After any resize: re-record, because nothing here scales alike

Numbers measured at one size do not transfer to another. At minimum, re-capture:

* **The parity report** — regenerated by the apply; commit it.
* **The reset timing** (#109 task 4.1). `truncate` is near O(1) and barely moves;
  `teardown` is O(rows) *and* sensitive to physical layout — the same 2.3M rows
  took 413s on freshly-loaded tables and 621s on fragmented ones.
* **`stats.json`** for the dataset (`tools/data-generator/validate_stats.sql`).
  Note that the observation sampling switches from exhaustive to 1% above
  500,000 rows, so percentiles either side of that threshold are not comparable.

## Do not change these for cost reasons

**The database must stay fixed-performance.** The module defaults to
`db.m6g.large` specifically to remove burstability while keeping production's
2 vCPU / 8 GiB. A `t`-family class runs on CPU credits and collapses when they
are exhausted, which is exactly the condition a sustained load test creates. The
parity report now derives "fixed" versus "BURSTABLE" from the class family
rather than asserting it, so an override of this kind is at least visible — but
visible is not the same as valid, and any number measured on a burstable class
should be discarded.
