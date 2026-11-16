# Write tunnels to the databases, for data fixes

Each database has a write tunnel: production, staging and prerelease. A person given one can reach that database from their laptop and nothing else. It is given for a fix and taken away when the fix is done.

Reading never needs one. Looking at data, checking a number or investigating a ticket uses the read copy (`avni-db up readcopy`). On production, writing is allowed for two reasons only: a data fix an organisation asked for, and a platform upgrade.

| Database | Tile on the sign-in page | Group | `avni-db` name | Laptop port |
|---|---|---|---|---|
| Production | AvniProdDbWrite | `ops-prod-db-write` | `prod-write` | 15436 |
| Staging | AvniStagingDbWrite | `ops-staging-db-write` | `staging-write` | 15437 |
| Prerelease | AvniPrereleaseDbWrite | `ops-prerelease-db-write` | `prerelease-write` | 15438 |

## Asking for one

Message a Samanvay Ops admin (Himesh, Joy, Om or Vinay), or open an issue on this repository, with:

1. Which database.
2. The organisations the fix touches, and a link to the reviewed fix or its ticket.
3. How many days you need. Three is usual.

The fix itself follows the data fix flow in avni-support-ops: someone other than its author reviews it, and the person who wrote it does not apply it.

## Using it

1. Run the laptop kit once if you have not: `sh configure/laptop/install.sh`. It adds the profiles for the write tiles.
2. `avni-db up prod-write` (or `staging-write`, `prerelease-write`). A browser tab opens to sign in when needed.
3. Connect your database tool to `localhost` on the port above, database `openchs`, with the organisation's own database login, or the main login when the fix needs it. The main login is the database's administrator login. The passwords are in the team vault.
4. Run the reviewed script.
5. `avni-db down prod-write` when done.

A tunnel closes after an hour with nothing passing through it, and after 8 hours in any case. Sign-in on the production tile lasts 4 hours, the others 8.

## For admins: giving and taking away

Giving: IAM Identity Center → Groups → the group → **Add users** → the person. Tell them the end date.

Taking away, on the end date, both steps:

1. Groups → the group → select the person → **Remove**.
2. Close any tunnel they still have open. Removing someone from the group does not close it, and a sign-in they made before removal keeps working for up to 4 hours on production and 8 on the others.

```
aws ssm describe-sessions --region ap-south-1 --state Active \
  --query 'Sessions[?DocumentName==`Avni-ProdDbWriteTunnel`].[SessionId,Owner,StartDate]' --output text
aws ssm terminate-session --region ap-south-1 --session-id <id>
```

Use `Avni-StagingDbWriteTunnel` or `Avni-PrereleaseDbWriteTunnel` for the others. The write groups should be empty whenever no fix is under way.

## What this does not do

- The database passwords do not change after a fix. Someone given a tunnel once still knows them; without the tile they cannot reach the database from a laptop.
- The database does not record who ran what, since people share the database logins. AWS records who opened which tunnel and when.
- People with a server tile (AvniServersNonProd, AvniServersProd) can already reach these databases through it.

## How it is built

Each tile can start one Session Manager document on one server, and each document is a port forward pinned to its database's address on 5432, so the person cannot choose another destination. Created and tested on 16 Nov 2026; the script and checks are in avni-product-ops, `analysis/infra-hardening-nov-2026/backups/db-write-tunnels-16nov/`.

| Document | Database address | Through server |
|---|---|---|
| `Avni-ProdDbWriteTunnel` | `proddb02.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com` | `i-07df2679f68762a68` |
| `Avni-StagingDbWriteTunnel` | `staging-db.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com` | `i-0879e9c88952968ea` |
| `Avni-PrereleaseDbWriteTunnel` | `prerelease-db-20260804.cnwnxgm8rsnb.ap-south-1.rds.amazonaws.com` | `i-0cdce9ae698eb3462` |

When the prerelease database is rebuilt under a new name, update the address in `Avni-PrereleaseDbWriteTunnel` in the same change. Until then the tunnel fails closed.
