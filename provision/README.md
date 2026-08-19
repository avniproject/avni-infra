### Provision servers
This directory contains Terraform scripts that are used to provision Avni. 

There are a few configuration scripts here as well that allow deployment of Avni server. However, this will be soon moved to the ```../configure``` section. 

---

## ⚠️ Do not run `terraform apply` in `server/` against production

**The Terraform in `server/` does not describe the live production environment.** It has drifted far enough that applying it would be destructive, not corrective.

Concretely, `server/` is pinned to AWS provider `1.7` (`provider.tf`) and uses Terraform 0.11 syntax. It declares `enable_classiclink` (`networking.tf`), an argument removed from the provider years ago, so it will not `plan` on a current toolchain at all. Where it does parse, it describes a database that no longer exists: `engine_version = "12.7"` and `db.t2.small` in `database.tf`, against a live production instance running PostgreSQL 16.8. It also carries `storage_encrypted = false` and a literal `password = "password"`.

Applied against the production workspace, Terraform would plan to **replace the database instance**, and `aws_instance.server` carries `key_name`, which is immutable — so it would plan to **replace the server** as well.

**Consequently:**

- Treat every `.tf` file in `server/` as a historical record, not as the source of truth.
- Make infrastructure changes to production out of band — console or CLI — and update these files afterwards so they document what was done.
- `server-override/from_prerelease_override.tf` is the exception that is genuinely used: `make create-prerelease-from-prod` applies it to build prerelease from the latest production snapshot. Prerelease is therefore governed as a production environment rather than a test one — see the production access standard in `avni-product-ops`.

Rebuilding an accurate description of production infrastructure is worth doing and is tracked separately. Until it is done, this warning is the control.
