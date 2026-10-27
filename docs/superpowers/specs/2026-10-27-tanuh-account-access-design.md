# Access to the Tanuh AWS accounts

Status: approved by the Samanvay Ops admins. The setup steps are in `docs/identity-center/setup.md` and adding or removing people is in `docs/identity-center/people-runbook.md`. Where this document and those two differ, they are the current version.

This records a discussion held on 2026-10-27 in the `tanuh-samanvay-infra` repository, so the work can continue in `avni-infra`.

## Goal

An easy way to give a person access to the Tanuh AWS accounts with one of three roles:

1. **Read-only.** Inspect the infrastructure without changing it. Typical user: a tester.
2. **Developer.** Debug services, including SSH into EC2 instances, and see billing.
3. **Admin.** Make infrastructure changes.

## Accounts

| Account | State |
|---|---|
| Samanvay Ops (management account) | Existing organization. Runs Avni staging, UAT and production. Everyone uses IAM users. Managed by hand, and will stay that way. |
| `tanuh-staging` | In use by two Samanvay admins. |
| `tanuh-prod` | Empty. To be handled later. |

Both Tanuh accounts are in the `Tanuh` OU, region `ap-south-1`. Their foundations (state bucket, CloudTrail, VPC) are managed by `TANUH-AI/tanuh-samanvay-infra`. Its `docs/setup/` folder holds the account setup steps and the SCPs applied to the OU.

## Requirements

- Tanuh people must have no access to the Samanvay Ops organization. They reach only the Tanuh accounts.
- Samanvay people are the main operators of the Tanuh accounts, so their sign-in matters as much as Tanuh's.
- Most users will do technical work. At least some need the AWS CLI, and SSH into EC2 from their laptops.
- People are grouped by organization, so when a client leaves, everyone from that client can be found and removed.
- Existing IAM users in Samanvay Ops keep working unchanged.
- The setup can grow to other clients, each with their own accounts and their own people.
- Samanvay Ops is managed by hand. Anything in the management account is either a console step or a CLI script run from a laptop, in the style of avni-infra's existing scripts.

## Options considered

### IAM users in Samanvay Ops, assuming roles into the Tanuh accounts

This is how the existing admins work today. It was rejected for Tanuh people because they would then be IAM identities in the parent, able to reach its console sign-in page even with no permissions. Each user also carries a permanent password and usually an access key.

### IAM users inside each Tanuh account

This keeps Tanuh people out of the parent. The costs:

- permanent passwords and access keys
- MFA enforced by a deny-without-MFA policy in each account
- offboarding done account by account
- prod doubling the work

One login per person is possible if users live in one account and assume roles into the others. This is the **fallback if the other admins don't agree to Identity Center.**

### IAM federation with Google Workspace, per account

Samanvay and Tanuh each have their own Google Workspace. An AWS account can trust several SAML providers, so each Tanuh account could trust both Workspaces. People would sign in with their company Google account into the role their Workspace admin assigns. Each role can name which providers it accepts, for example Admin accepting only Samanvay's.

This was rejected because the AWS CLI cannot use this sign-in without third-party helpers such as `saml2aws` or `gsts`. Those helpers break when Google changes its sign-in page, and most users need the CLI.

### Identity Center with Google Workspace as the identity source

With Identity Center in between, the CLI problem goes away: `aws sso login` works the same with any identity source. It was rejected for these reasons:

- **One identity source per organization.** Identity Center can trust Samanvay's Workspace or Tanuh's, not both. Tanuh people could only sign in if they had accounts in Samanvay's Workspace, either on Samanvay's domain or with Tanuh's domain added to it. Neither organization wants that. Several clients' login systems would need a broker in between, such as Okta, Auth0 or Keycloak. That means a cost or a service to run, and a single point that affects every client.
- **Groups are not synced from Google.** Google's automatic provisioning sends users only. With an external identity source, the console cannot create groups. They must be created and filled through the Identity Store API or a sync tool such as `ssosync`. That conflicts with managing Samanvay Ops by hand.
- **MFA moves to Google.** Identity Center's MFA settings stop applying, so 2-step verification would have to be enforced in the Workspace.

What it would give: one less password for Samanvay people, and access that ends automatically when someone's Google account is suspended. With about 15 Samanvay users and 5 Tanuh users, all stable for months at a time, that doesn't outweigh the above.

The choice can be revisited. Switching from the built-in directory to an external identity source keeps users, groups, memberships and assignments, provided the provider's SAML `NameID` (the email) matches each Identity Center username. This is why usernames are set to the work email.

### Identity Center with its built-in directory (chosen)

Users are created in Identity Center's own directory with any email address, from any organization. They sign in with an Identity Center password and MFA.

Compared with IAM users:

- **No permanent credentials.** `aws sso login` gives the CLI temporary credentials. There are no IAM passwords or access keys to leak or rotate.
- **MFA required at sign-in** for console and CLI, without per-account policies or `mfa_serial` profiles.
- **Users aren't IAM identities in any account.** A Tanuh user sees only the accounts assigned to them, and has nothing in Samanvay Ops.
- **No cross-account plumbing.** Identity Center creates the roles in assigned accounts. `aws configure sso` writes the CLI profiles.
- **Self-service onboarding.** Users get an invitation email, and reset forgotten passwords by email.

What it costs:

- No sign-in with Google. People have one more password and MFA device.
- It's an organization-wide feature in the management account, so the other Samanvay Ops admins must agree.
- Identity Center itself has no charge.

## Design

### One-time console setup in Samanvay Ops

AWS only allows turning on the organization instance of Identity Center from the console. These steps go in a runbook.

- **Home region `ap-south-1`.** It cannot be changed later without deleting the instance, which loses every user and assignment.
- **Identity source: the built-in directory.** It can be switched to an external provider later without recreating users (see above).
- **MFA required for every sign-in.**
- **Session length per permission set:** Read-only 8 hours, Developer 8 hours, Admin 4 hours.

Things to know before turning it on:

- **Existing IAM users, roles and keys in every account are unaffected.**
- **Roles appear in assigned accounts with generated names**, for example `AWSReservedSSO_Developer_<suffix>`. Identity Center owns them, and they can't be edited in the account. Any bucket, KMS or trust policy that names a role must match these names with a wildcard.
- **Only management-account admins can manage it** unless administration is delegated to another account.
- **Deleting the instance removes every permission set and the roles it created.**

### Permission sets

| Permission set | Policies | Notes |
|---|---|---|
| Read-only | `ViewOnlyAccess`, plus logs and metrics reads, secrets under `readonly/`, and Session Manager port forwarding only through instances tagged `db-tunnel = true` | For testers. The accounts will hold personal data, so they don't get `ReadOnlyAccess`, which includes `s3:GetObject` on every bucket and Lambda and ECS environment variables. Each service grants its S3 documents explicitly. |
| Developer | `ReadOnlyAccess`, `AWSBillingReadOnlyAccess`, SSH and port forwarding through Session Manager on any instance, `ecs:ExecuteCommand`, restarting EC2 instances, ECS tasks and RDS instances, secrets under `readonly/` | Cannot create, change or delete resources. Reads personal data in S3 unless it is encrypted with a customer-managed key. |
| Admin | `AdministratorAccess` | Samanvay only. Still bound by the Tanuh OU's SCPs. |

Database inspection uses a read-only database user. Its credentials are kept in Secrets Manager under `readonly/<service>`, and the database is reached by forwarding a port through Session Manager.

The policy JSON is kept in the repository and pasted into the console, so it is reviewed and versioned even though it is applied by hand.

### Groups and assignments

Access is granted to groups, never to individual users. There is one group per organization per role:

| Group | Permission set | Accounts |
|---|---|---|
| `tanuh-readonly` | Read-only | `tanuh-staging` |
| `tanuh-developers` | Developer | `tanuh-staging` |
| `samanvay-readonly` | Read-only | `tanuh-staging` |
| `samanvay-developers` | Developer | `tanuh-staging`, `tanuh-prod` |
| `samanvay-admins` | Admin | `tanuh-staging`, `tanuh-prod` |

`tanuh-admins` has Admin on `tanuh-staging`. A tester who needs prod goes into a separate `<org>-readonly-prod` group, so that prod access is given per person and not to every tester.

Identity Center does not record which organization a user belongs to, so the group prefix carries that. The rule: a person is only ever in their own organization's groups. A Tanuh user put in a `samanvay-*` group would be missed when Tanuh's access is removed.

When a new client arrives, it gets its own groups with its own prefix, assigned only to its own accounts.

### Script for people

People are managed by hand in the console first, following the runbook. The script is a later, optional step.

A script in `provision/scripts/`, in the style of `readonly-users.sh`, run with management-account credentials. Its jobs:

- add a user (create in the Identity Store if missing, and send the invitation) and put them in a group
- `--show`: list each group, its members and its account assignments, read from AWS
- remove one user
- remove an organization: delete every user in `<org>-*` groups, then the groups
- refuse to run unless the caller is in the management account

It follows the conventions of `readonly-users.sh`:

- usernames are arguments and are never committed
- users stay out of OpenTofu so people don't appear in infrastructure diffs
- `--show` is the record of who has access

The CLI services involved are `identitystore` (users, groups, memberships) and `sso-admin` (permission sets, account assignments).

### SSH into EC2

SSH runs over Session Manager (the `AWS-StartSSHSession` document), with the key put on the instance for 60 seconds through EC2 Instance Connect's `SendSSHPublicKey`:

- No public IP on instances, no inbound rule, and no long-lived SSH keys on them. Instances need the SSM agent and an instance profile with `AmazonSSMManagedInstanceCore`.
- Authorization is IAM: `ssm:StartSession` limited to named documents, and `ec2-instance-connect:SendSSHPublicKey`.
- `ssh`, `scp`, `ssh -L` and VS Code Remote-SSH work as usual, through a ProxyCommand script in `tanuh-samanvay-infra` that finds the instance by its `Name` tag.
- ECS exec uses Session Manager too, so there is one mechanism for instances and containers.

An EC2 Instance Connect endpoint was considered and briefly applied in staging. It was dropped because Session Manager was already in use by DQS, covers ECS exec, can limit testers to port forwarding with no shell, and can log session contents if needed.

### Existing admins

The two admins keep their Samanvay Ops IAM users and keep assuming roles into `tanuh-staging` for `tofu` work. They can move to Identity Center later, one at a time.

## Where the pieces live

In `avni-infra`, since Identity Center belongs to Samanvay Ops:

- this design
- a runbook covering the console setup, creating permission sets and groups, adding a user, and removing a client
- the permission set policy JSON
- the people script

In `tanuh-samanvay-infra`:

- the guide for users (`docs/access/`): shared `~/.aws/config` and `~/.ssh/config` blocks, `aws sso login`, exporting the session for `tofu`, SSH and database tunnels
- `scripts/ssh-proxy.sh` and `scripts/db-tunnel.sh`
- Session Manager's preferences in `bootstrap/`

## To check before building

- **The Tanuh OU's SCPs** in `tanuh-samanvay-infra/docs/setup/`, especially `scp-tanuh-deny-cross-account.json`. They must not block Identity Center's roles or sign-in.
- **The tofu state KMS key policy** (`alias/tanuh-tfstate`) in each Tanuh account. If it delegates to the account through IAM, the Admin permission set can use it. If it names specific roles, it needs the `AWSReservedSSO_Admin_*` pattern.
- **Billing visibility from a member account.** `AWSBillingReadOnlyAccess` only works if IAM access to billing is activated in the member account (a root-user setting). Cost Explorer for member accounts can also be restricted by the management account.
- **Whether `ReadOnlyAccess` includes the CloudWatch Logs reads a tester needs,** or whether Read-only should also get Logs Insights queries.

## Decisions on the open questions

1. The Samanvay Ops admins agreed to turn on Identity Center.
2. A permanent `tanuh-admins` group has Admin on staging, for Tanuh people such as their architect. Prod is a separate decision.
3. Developer can restart instances, tasks and databases, exec into containers, SSH, and read secrets under `readonly/`. Read-only is for testers, who need logs, database inspection and S3 documents.
4. Session lengths: Read-only 8 hours, Developer 8 hours, Admin 4 hours.
5. Testers get staging by default. Prod can be given to a person through a `-readonly-prod` group.
6. People reach instances through Session Manager, with SSH running over it. The guide and scripts live in `tanuh-samanvay-infra`.

Still open: how logs are collected. The permission sets assume CloudWatch Logs.

## Removing access

Deleting a user stops new sign-ins. Credentials already issued for an account stay valid until the permission set's session length ends. End the user's active sessions before deleting them, because the console can't do it afterwards. To cut off issued credentials at once, add a deny on `aws:TokenIssueTime` to the permission set. The runbook has the steps.
