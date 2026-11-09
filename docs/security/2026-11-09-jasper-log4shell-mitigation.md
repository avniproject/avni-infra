# Jasper Log4Shell (CVE-2021-44228) mitigation

- **Date:** 2026-11-09
- **Host:** `reporting-jasper` (`i-04e63258909c9d995`, `reporting-jasper.avniproject.org`)
- **Tracking:** avniproject/avni-infra#122 (incident task-list row 90)
- **Status:** Mitigated and verified; reporting back up.

## Background

JasperReports Server CE 7.5.0 bundled `log4j-core-2.12.1.jar` with `JndiLookup.class`
present, so the Log4Shell (CVE-2021-44228) family was unmitigated. The host is
internet-facing and its `WEB-INF/META-INF/context.xml` holds the `openchs` DB owner
credential for the prod writer (`serverdb.avniproject.org`). Because the `openchs`
owner role is not constrained by row-level security, an RCE here could read/write the
entire production database across all organisations. This was mitigated ahead of the
full host migration (#73).

## Action taken

On `reporting-jasper`:

1. Backed up the jar -> `/root/log4j-core-2.12.1.jar.bak-20261109`
   (md5 `0138ba1c191d5c754fd0e3c3a61c0307`).
2. Removed `org/apache/logging/log4j/core/lookup/JndiLookup.class` from
   `/var/lib/tomcat9/webapps/jasperserver/WEB-INF/lib/log4j-core-2.12.1.jar`.
   The host has no `zip`, so a python3 `zipfile` rewrite was used; owner
   `tomcat:tomcat` preserved. Patched jar md5 `a570e8896b24afaea2894ef19cd691f2`
   (1186 entries).
3. `systemctl restart tomcat9`.

## Verification

- `JndiLookup.class` absent from the jar and still absent after the restart.
- `tomcat9` active; `http://localhost:8080/jasperserver/login.html` -> 200.
- External `https://reporting-jasper.avniproject.org/jasperserver/login.html` -> 200;
  `rest_v2/serverInfo` responds (v7.5.0).

## Rollback

Restore `/root/log4j-core-2.12.1.jar.bak-20261109` over the jar and restart `tomcat9`.

## Forensics (no evidence of exploitation; not fully provable)

Host forensics were clean: no web shells, no rogue processes/cron/users, `/etc/passwd`
unchanged since 2020. Historical exploitation cannot be fully disproven: RDS had no
statement/connection logging, Performance Insights retains only 7 days (last-7-day load
is normal Metabase + Jasper `set role <org>` patterns, no rogue DB user), Jasper's own
audit was disabled (`feature.audit_monitoring.enabled=false`), Jasper app logs retain
~10 days, and there are no DNS logs to catch a `jndi` callback.

## Residual follow-ups (not closed by this)

- Treat the `openchs` prod DB credential as **exposed** (it sat readable on this
  RCE-vulnerable, internet-facing host) and rotate it. The rotation window **must**
  update Jasper's `context.xml` or Jasper breaks. (Incident task-list row 21.)
- Full migration off Ubuntu 18.04 / Java 8 / Jasper 7.5.0, or retire Jasper (#73).
  Jasper 7.5.0 also has other CVEs (RCE CVE-2022-41561/62/63, XXE CVE-2021-35496).
- Stop `rest_v2/serverInfo` leaking the version unauthenticated.
- Enable RDS `log_connections` / `pgaudit` for the `openchs` role (or extend PI
  retention) so future access is auditable.

## Update: RWB Jasper also mitigated (9 Nov 2026)

`jasper.rwb.avniproject.org` (`rwb-reporting-jasper`, separate AWS account) was found to
be the **same** legacy Tomcat9 + Jasper 7.5.0 install (the Jan-2024 docker/nginx 8.2.0
migration in `configure/roles/jasperserver` was written but never deployed). It had the
same unmitigated `JndiLookup.class`.

- Backed up `/root/log4j-core-2.12.1.jar.bak-20261109`, removed `JndiLookup.class`
  (python3 rewrite), restarted `tomcat9`, verified login 200 internally and externally.
- Repo datasource connects as `jasperreports` (not an owner role) to
  `stagingdb.rwb.avniproject.org/jasperserver`, so blast radius is smaller than prod.
- Access logs showed only health-check traffic (serverInfo + `/`) from two internal IPs
  — likely stale; kept up per Joy's call ("not sure about usage, safer to fix and keep up").

## Note on the boxes

Both Jasper hosts are dedicated (only tomcat9 + ssh; no docker/db/other apps). Both were
cloned from the same 2020 golden image carrying the vulnerable jar (service lineage
Log4Shell-exposed since Dec 2021; current VMs launched 2024). Reports/users live in the
RDS `jasperserver` DB, so they survive a VM rebuild. Plan: rebuild prod on a fresh image
(not the golden AMI) with the fixed provision script, stop-not-delete the old box for disk
backup, then delete; rotate the `openchs` cred in the same window.

## Forensic scans (9 Nov 2026) — both boxes CLEAN

Before retiring each old box, a read-only forensic triage was run while it was still live.
Both came back with **no evidence of compromise**: no persistence (cron/systemd/rc/
authorized_keys), no web-shells (all `.jsp` are the stock 2019 Jasper build), no rogue OS
or Jasper-app accounts (jiuser/jirole only known staff/orgs), no miners, no unexpected
outbound, and `dpkg -V` clean except benign snapd churn. Every `${jndi:...}` probe in the
logs (2021-2026) was recorded by Tomcat's cookie parser
(`org.apache.tomcat.util.http.parser.Cookie`, java.util.logging) — the harmless sink —
never a log4j logger. Honest gaps: the Dec-2021 app-log window has rotated away, auth.log
retains only ~3 weeks, `dpkg -V` can't detect a rootkit that subverts it, and fileless/
historical activity can't be excluded from a live triage. Net: scanned heavily, not
successfully exploited.

(A follow-up DB-password rotation is tracked privately in the incident task-list, row 21.)

## Rebuild onto clean boxes (9 Nov 2026)

Because an exploitable, internet-facing box can never be fully trusted, both Jaspers were
rebuilt onto fresh stock-OS instances (stop-not-destroy the old ones, disk snapshot kept).
Reports/users were untouched — they live in the RDS `jasperserver` DB; each new box just
re-points at the same DB via a mirrored `context.xml`. No DB re-init was done (the Jasper
installer was NOT run; the already-configured, patched webapp was mirrored instead).

**Method (both):** launch a fresh stock Ubuntu 18.04 box (same subnet/SG/key/type as the
old one) → install `openjdk-8-jdk` + `tomcat9` → deploy a tar bundle mirrored from the old
(already-patched) box: the `jasperserver` webapp (JndiLookup already removed), the Jasper
Tomcat libs (`jasper.jar`, `postgresql-42.2.5.jar`, `mariadb-java-client-1.6.3.jar`), and
the `/opt/jasper-config/.jrsks`/`.jrsksp` keystore (needed to decrypt stored datasource
passwords) → set `JAVA_OPTS` → start → verify `serverInfo` 200/7.5.0 → register in the ALB
target group, wait healthy, deregister old → snapshot + stop old.

### Prod (account 118388513628)
- New box: `i-01b3088ce4a942a88`, from **stock Canonical bionic `ami-0b44050b2d893d5f7`**
  (NOT the 2020 golden/custom image). t3.small, 20 GB gp3.
- ALB: registered in `reporting-jasper-loadbalancer-tg`, old deregistered; public URL 200.
- DNS: `ssh.reporting-jasper.avniproject.org` A record -> new box IP.
- Old box `i-04e63258909c9d995`: snapshot `snap-03cbf796776a7b3ff` (completed), **stopped**.
- Provision script fixed so future rebuilds strip JndiLookup (commit `8484b8c`).

### RWB (account 730335671779) — run from CloudShell
- The IAM user `ombhardwaj` cannot `sts:AssumeRole` the `rwb` role even with MFA, so the
  rebuild was run by the operator in AWS CloudShell after a console switch-role.
- The RWB box's own AMI `ami-020336bcde45898af` ("AvniJasper", a **custom** image owned by
  the prod account) **failed to boot cross-account** (encrypted snapshot / KMS key not
  shared with the RWB account). Fell back to **stock Canonical bionic `ami-00f994c719fc62e9e`**
  (resolved via the Canonical SSM public parameter in the RWB account).
- Gotcha: the old box had **two** security groups (`sg-05344afd119f087d1` +
  `sg-02fe15d47e8a76901`); only the first was discovered/applied at launch, so the new box
  couldn't be reached until both were applied (`modify-instance-attribute --groups`).
- New box: `i-074eac2e08fe73cc0`. ALB: registered in `reporting-jasper-tg`, old
  deregistered; `jasper.rwb` login 200.
- Old box `i-07a455f79fc965ded`: snapshot `snap-09d9bf7de2b4dd63b`, **stopping/stopped**.
- Runbook used: team scratchpad `rwb-jasper-rebuild-runbook.md` (not committed).

### Still open after the rebuild
- **Rotate the affected DB credentials** and update BOTH new boxes' `context.xml`
  (critical; details + scope in incident task-list row 21).
- Terminate the old boxes once their snapshots read 100%, and the orphaned failed-launch
  box `i-0586ef397206765e9` (RWB account).
- Delete install-staging log4j copies under `/home/ubuntu` on both new boxes.
- Neither new box is in Tofu/IaC state (both rebuilt manually) — reconcile later; prod
  Jasper's `provision/reporting-jasper` is still legacy Terraform, RWB has no `.tf` at all.
