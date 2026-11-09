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
