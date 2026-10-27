# IAM Identity Center for the Tanuh accounts: setup

One-time setup of IAM Identity Center in Samanvay Ops, so people can sign in to `tanuh-staging` and `tanuh-prod` with one of three roles. The design and the options rejected are in `docs/superpowers/specs/2026-10-27-tanuh-account-access-design.md`. Adding and removing people is in `people-runbook.md` next to this file.

Everything in Samanvay Ops is done by hand in the console. SSH and database access (section 7) need no infrastructure in Samanvay Ops; what they need in the Tanuh accounts is in `tanuh-samanvay-infra`.

## Accounts

| Account | Role here |
|---|---|
| Samanvay Ops (management) | Holds Identity Center. Runs Avni staging, UAT and production. |
| `tanuh-staging` | Receives assignments. |
| `tanuh-prod` | Receives assignments. |

The account IDs are in the AWS Organizations console, and the Tanuh ones in `tanuh-samanvay-infra`'s `docs/access/aws-config`.

Region: `ap-south-1` is Identity Center's home region, where its users and settings live, and the region of the Tanuh accounts. It does not limit where people can work. Samanvay Ops resources in Singapore and global services are unaffected. The Read-only and Developer policies name `ap-south-1` in their secret and Session Manager ARNs. Reusing them for accounts in another region means editing those ARNs.

Approved by the Samanvay Ops admins.

## Impact on Samanvay Ops

Samanvay Ops runs production, so this is what turning on Identity Center changes there, and what it does not.

Changes:

- **Trusted access for IAM Identity Center is turned on in AWS Organizations.**
- **A service-linked role, `AWSServiceRoleForSSO`, is created in the management account and in every member account.** It lets Identity Center create roles in accounts it is assigned to. It grants no person anything.
- **Anyone with admin rights in the management account can manage Identity Center.** That includes giving themselves any permission set in any account. The four admins already have that power through IAM, so no one gains anything new.
- **New roles named `AWSReservedSSO_<permission set>_<suffix>` appear in an account, but only in accounts with an assignment.** With the assignments in section 6, that means only the two Tanuh accounts.

Unchanged:

- Existing IAM users, groups, roles, policies and access keys in every account.
- Avni workloads, the `avni-*` CLI profiles and scripts, and the `tanuh-cli-*` users and `OrganizationAccountAccessRole` path the Tanuh admins use today.
- SCPs.

Rules that protect production:

- **Never assign a Tanuh access permission set (Admin, Developer, Read-only) to the management account.** SCPs do not apply to the management account, so an assignment there has no guardrail. The `samanvay-*` groups exist for the Tanuh accounts only; management-account access, if wanted, gets its own group. Section 8 checks for one.
- **The `Billing` permission set predates this setup.** It is assigned in the management account to the group `Billing` and to one user directly, for billing work. Leave it as it is.
- **Never assign a Tanuh group to a Samanvay Ops account.**

If Identity Center is ever deleted, every user, group, permission set and assignment is lost, along with the `AWSReservedSSO_*` roles it created. Existing IAM access keeps working.

## Decisions

| Item | Decision | Reason |
|---|---|---|
| Identity source | Identity Center directory | Users from any organization, any email address. Can be switched to an external provider later; AWS keeps users, groups and assignments when it is |
| Home region | `ap-south-1` | Cannot be changed without deleting the instance |
| MFA | Every sign-in; register a device at first sign-in | No per-account MFA policies needed |
| Session length | Read-only 8 h, Developer 8 h, Admin 4 h | Users are stable; a working day without signing in again. Admin is shorter because it can change infrastructure |
| Delegated administration | Not used | Managed from the management account by the four admins |
| Member-account Identity Center instances | Disabled | A member account cannot start its own Identity Center |
| Identity-enhanced sessions | Off | Only needed for Amazon Q Developer Pro subscriptions in the console. Applies org-wide, including to IAM users in the management account |
| Tanuh admins | Permanent `tanuh-admins` group, Admin on staging | Available when a Tanuh person, such as their architect, needs to change infrastructure. Samanvay admins remain the main operators |
| Tester access to prod | Not by default; possible per person | See `people-runbook.md`, "Give a tester access to prod" |

## 1. Turn on Identity Center

Identity Center was already turned on in `ap-south-1`, with the `Billing` permission set from December 2024. Skip to section 2 and check its settings. The steps below are for a new organization.

Sign in to the management account with an admin IAM user. Set the console region to **Asia Pacific (Mumbai) ap-south-1** first. The region in use when you click Enable becomes the home region.

1. IAM Identity Center → **Enable**.
2. Choose **Enable with AWS Organizations**. Do not choose an account instance.
3. Wait until the dashboard shows the AWS access portal URL and the identity source "Identity Center directory".

## 2. Settings

IAM Identity Center → Settings.

1. **Identity source** tab: leave as Identity Center directory.
2. **AWS access portal URL**: Actions → Customize, and set the subdomain to `samanvay`, giving `https://samanvay.awsapps.com/start`. Pick the subdomain carefully: it can be customized only once. The URL must end in `/start`; without it AWS returns 403.
3. **Authentication** tab → Multi-factor authentication → Configure:
   - Prompt users for MFA: **Every time they sign in (always-on)**
   - Users can authenticate with: **Security keys and built-in authenticators** and **Authenticator apps**
   - If a user does not yet have a registered MFA device: **Require them to register an MFA device at sign in**
   - Who can manage MFA devices: **Users can add and manage their own MFA devices**
4. **Authentication** tab → Session settings: leave the access portal session at its default of 8 hours.
5. **Management** tab → Account instances of IAM Identity Center: **Disable**, if it is shown as enabled.

## 3. Prerequisites in the Tanuh accounts

Do these before the first test sign-in.

### Billing visibility

Developer includes `AWSBillingReadOnlyAccess`. It only works in a member account where IAM access to billing is turned on.

1. Sign in to `tanuh-staging` as its root user. The credentials are with the admins, per `tanuh-samanvay-infra/docs/setup/aws-account-setup.md` section 4.
2. Account → **IAM user and role access to Billing information** → Edit → Activate.
3. Repeat for `tanuh-prod`.
4. In the management account: Billing and Cost Management → Cost Management preferences → check that **Linked account access** is allowed. This lets member accounts see their own costs in Cost Explorer. It does not show them any other account's costs.

### State key

The Admin permission set uses `alias/tanuh-tfstate` in each Tanuh account. In KMS, check that the key policy is the default one that starts with `"Sid": "Enable IAM User Permissions"` and `"AWS": "arn:aws:iam::<account>:root"`. If it is, IAM permissions alone decide access and nothing needs to change. If it names specific roles, add `arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/ap-south-1/AWSReservedSSO_Admin_*` with an `ArnLike` condition on `aws:PrincipalArn`.

## 4. Permission sets

IAM Identity Center → Multi-account permissions → Permission sets → Create permission set → **Custom permission set**.

Name them exactly as below. The names become part of the role names in each account.

Finding the managed policies: the Custom permission set list may not show `ReadOnlyAccess` or `ViewOnlyAccess`. They were missing on 2026-10-27. If so, create the permission set as **Predefined permission set** → that policy, with the name and session duration below. Then open it and attach the other managed policies and the inline policy. The full ARNs:

| Policy | ARN |
|---|---|
| `ViewOnlyAccess` | `arn:aws:iam::aws:policy/job-function/ViewOnlyAccess` |
| `ReadOnlyAccess` | `arn:aws:iam::aws:policy/ReadOnlyAccess` |
| `AWSBillingReadOnlyAccess` | `arn:aws:iam::aws:policy/AWSBillingReadOnlyAccess` |
| `AdministratorAccess` | `arn:aws:iam::aws:policy/AdministratorAccess` |

If the console won't show one, attach it by ARN after creating the permission set: `aws sso-admin attach-managed-policy-to-permission-set --instance-arn <instance arn> --permission-set-arn <permission set arn> --managed-policy-arn <arn> --region ap-south-1`.

### `Read-only`

For testers. Sees configuration and logs, and the data a service grants it (section 9). It doesn't get the blanket S3 and Lambda/ECS environment reads that come with `ReadOnlyAccess`, because the accounts will hold personal data.

- AWS managed policies: `ViewOnlyAccess`
- Inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LogsRead",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:DescribeQueries",
        "logs:GetLogEvents",
        "logs:GetLogGroupFields",
        "logs:GetQueryResults",
        "logs:FilterLogEvents",
        "logs:StartQuery",
        "logs:StopQuery",
        "logs:StartLiveTail",
        "logs:StopLiveTail"
      ],
      "Resource": "*"
    },
    {
      "Sid": "MetricsRead",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:DescribeAlarms",
        "cloudwatch:GetDashboard",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListDashboards",
        "cloudwatch:ListMetrics"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ReadOnlyDatabaseCredentials",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:ap-south-1:*:secret:readonly/*"
    },
    {
      "Sid": "FindInstances",
      "Effect": "Allow",
      "Action": "ec2:DescribeInstances",
      "Resource": "*"
    },
    {
      "Sid": "PortForwardThroughTunnelHostsOnly",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "arn:aws:ec2:ap-south-1:*:instance/*",
      "Condition": {
        "StringEquals": { "ssm:resourceTag/db-tunnel": "true" },
        "BoolIfExists": { "ssm:SessionDocumentAccessCheck": "true" }
      }
    },
    {
      "Sid": "PortForwardDocumentOnly",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": "arn:aws:ssm:ap-south-1::document/AWS-StartPortForwardingSessionToRemoteHost"
    },
    {
      "Sid": "EndSessions",
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": "arn:aws:ssm:ap-south-1:*:session/*"
    }
  ]
}
```

- Session duration: 8 hours.

`ssm:SessionDocumentAccessCheck` makes a session started without a document name, which would be a shell, need access to the shell document, which this set does not have. A Read-only user can therefore only forward a port, and only through an instance tagged `db-tunnel = true`.

### `Developer`

For debugging. Reads everything that `ReadOnlyAccess` reads. Can SSH into any instance and forward ports through it, exec into ECS containers, restart instances, tasks and databases, and see billing. Cannot create, change or delete resources.

- AWS managed policies: `ReadOnlyAccess`, `AWSBillingReadOnlyAccess`
- Inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SessionsOnAnyInstance",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ec2:ap-south-1:*:instance/*",
        "arn:aws:ssm:ap-south-1::document/AWS-StartSSHSession",
        "arn:aws:ssm:ap-south-1::document/AWS-StartPortForwardingSession",
        "arn:aws:ssm:ap-south-1::document/AWS-StartPortForwardingSessionToRemoteHost",
        "arn:aws:ssm:ap-south-1:*:document/SSM-SessionManagerRunShell"
      ],
      "Condition": { "BoolIfExists": { "ssm:SessionDocumentAccessCheck": "true" } }
    },
    {
      "Sid": "SshKeyForSessions",
      "Effect": "Allow",
      "Action": "ec2-instance-connect:SendSSHPublicKey",
      "Resource": "arn:aws:ec2:ap-south-1:*:instance/*"
    },
    {
      "Sid": "EndSessions",
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": "arn:aws:ssm:ap-south-1:*:session/*"
    },
    {
      "Sid": "Restart",
      "Effect": "Allow",
      "Action": [
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:RebootInstances",
        "ecs:StopTask",
        "rds:RebootDBInstance"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ExecIntoContainers",
      "Effect": "Allow",
      "Action": "ecs:ExecuteCommand",
      "Resource": "*"
    },
    {
      "Sid": "ReadOnlyDatabaseCredentials",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:ap-south-1:*:secret:readonly/*"
    }
  ]
}
```

- Session duration: 8 hours.

`ecs:StopTask` restarts a task in a service, because the service replaces it. `ecs:UpdateService` is left out because it can also change the task definition and the desired count, which amounts to deploying. `ReadOnlyAccess` includes `s3:GetObject` on every bucket, and Lambda and ECS environment variables. Every Developer can therefore read personal data in S3 unless it is encrypted with a customer-managed KMS key.

**A shell carries the instance's or task's own permissions.** After SSH or a Session Manager shell on an instance, or ECS exec into a container, a Developer can use that instance profile's or task role's credentials from the metadata endpoint. In effect a Developer can do whatever any service's role can do, including writing to its buckets and reading its secrets. Keep service roles narrow. Treat "Developer cannot change resources" as true only of the console and CLI.

### `Admin`

- AWS managed policies: `AdministratorAccess`
- Session duration: 4 hours.

In the Tanuh accounts it is still bound by the Tanuh OU's SCPs.

## 5. Groups

IAM Identity Center → Groups → Create group. Create a group only when its first member is added.

| Group | Who |
|---|---|
| `samanvay-admins` | Samanvay admins who change Tanuh infrastructure |
| `samanvay-developers` | Samanvay developers on Tanuh services |
| `samanvay-readonly` | Samanvay testers on Tanuh services |
| `tanuh-admins` | Tanuh people who change Tanuh infrastructure, such as their architect |
| `tanuh-developers` | Tanuh developers |
| `tanuh-readonly` | Tanuh testers |

Each group name starts with the person's organization. That prefix is the only record of which organization a person belongs to. A person is only ever in their own organization's groups.

## 6. Assignments

IAM Identity Center → AWS accounts → select the account → Assign users or groups → Groups → choose the group → choose the permission set.

| Group | Permission set | `tanuh-staging` | `tanuh-prod` |
|---|---|---|---|
| `samanvay-admins` | Admin | yes | yes |
| `samanvay-developers` | Developer | yes | yes |
| `samanvay-readonly` | Read-only | yes | no |
| `tanuh-admins` | Admin | yes | no |
| `tanuh-developers` | Developer | yes | no |
| `tanuh-readonly` | Read-only | yes | no |

**One group and one permission set per pass of the wizard.** It gives every selected group every selected permission set in every selected account. Selecting both accounts in one pass is fine when the group needs both. After each submit, open the account and check that its assignments show only the pair you meant.

To remove an assignment: AWS accounts → click the account name → **Users and groups** tab → select the group → **Remove access**.

Assign groups only, never individual users. When a permission set is first assigned to an account, Identity Center creates its role there. That role is named `AWSReservedSSO_<name>_<suffix>` and lives under the path `/aws-reserved/sso.amazonaws.com/ap-south-1/`.

## 7. SSH and database access

People reach instances through Session Manager: plain `ssh` runs over it, with the key put on the instance for 60 seconds through EC2 Instance Connect. Instances need no public address and no inbound rule, and there is no bastion or endpoint to run. The scripts, the shared `~/.aws/config` and `~/.ssh/config` blocks and the user guide are in `tanuh-samanvay-infra`'s `docs/access/`. Its `bootstrap/` module sets Session Manager's idle timeout to 60 minutes in each account.

Each service's instances need:

- An instance profile with `AmazonSSMManagedInstanceCore`, and a route out (the shared private subnets have one through the NAT gateway).
- A unique `Name` tag, such as `<service>-<env>`. People connect by that name.
- An AMI with the SSM agent, sshd and the EC2 Instance Connect package. Amazon Linux 2023 and Ubuntu 20.04 and later include all three.

For testers to reach a database, run a small instance tagged `db-tunnel = true` whose instance profile has only `AmazonSSMManagedInstanceCore`, and allow the database port from its security group. Do not put the tag on application instances. A port forward is relayed by the instance's agent, so it can reach the instance's metadata service and its role's credentials; that is why Read-only is limited to these instances.

## 8. Verify

Do the checks in order. Each depends on the one before it.

1. **Test user.** Follow `people-runbook.md` to add yourself with your own email, in `samanvay-developers`.
2. **Sign in** at the access portal URL and register MFA. The portal shows only `tanuh-staging` and `tanuh-prod`, each with Developer.
3. **Console.** Open `tanuh-staging` as Developer. EC2 and CloudWatch Logs pages load. Creating a security group is refused.
4. **CLI.** Follow `docs/access/README.md` in `tanuh-samanvay-infra`, then:
   ```bash
   aws sts get-caller-identity --profile tanuh-staging-developer
   # Arn: arn:aws:sts::<tanuh-staging account>:assumed-role/AWSReservedSSO_Developer_.../<you>
   ```
5. **SCPs.** In the same session, list S3 buckets. It succeeds. Listing EC2 instances in `us-east-1` is refused by the region SCP:
   ```bash
   aws s3 ls --profile tanuh-staging-developer
   aws ec2 describe-instances --region us-east-1 --profile tanuh-staging-developer   # AccessDenied / UnauthorizedOperation
   ```
6. **Billing.** As Developer in `tanuh-staging`, Billing and Cost Management → Bills loads, and Cost Explorer shows only that account's costs.
7. **Nothing in the management account.** Run each permission set through this check, signed in as your IAM user. The management account must not appear for any of them except `Billing`:
   ```bash
   aws sso-admin list-instances --region ap-south-1 --profile <your management profile>
   aws sso-admin list-permission-sets --instance-arn <instance arn> --region ap-south-1 --profile <your management profile>
   aws sso-admin list-accounts-for-provisioned-permission-set \
     --instance-arn <instance arn> --permission-set-arn <permission set arn> \
     --region ap-south-1 --profile <your management profile>
   ```
   In the console, IAM Identity Center → AWS accounts → Samanvay Ops shows only the `Billing` assignments. From the CLI, a profile with `sso_account_id` set to the management account and `sso_role_name` set to `Admin`, `Developer` or `Read-only` gets `ForbiddenException ... No access` from `aws sts get-caller-identity`.
8. **Prod.** As Developer, `aws sts get-caller-identity --profile tanuh-prod-developer` works and `--profile tanuh-prod-readonly` gets `No access`.
9. **Read-only.** Move yourself to `samanvay-readonly`, then `aws sso logout && aws sso login --sso-session samanvay` (the CLI keeps role credentials it already has until they expire), and open `tanuh-staging` as Read-only:
   - CloudWatch Logs Insights runs a query.
   - Downloading an object from the tofu state bucket is refused.
   - Lambda → a function → Configuration → Environment variables is refused.

   If either of the last two succeeds, `ViewOnlyAccess` reaches further than this document assumes. Stop, and review the permission set before any Tanuh tester is added.
10. **SSH.** As Developer, with `tanuh-samanvay-infra`'s `docs/access/` set up, `ssh dqs-staging.tanuh-staging` opens a shell.
11. **Tester tunnel**, once an instance tagged `db-tunnel = true` exists. As Read-only, `scripts/db-tunnel.sh` through that instance succeeds. Through an untagged instance it fails with AccessDenied, and `aws ssm start-session --target <tagged instance>` (a shell) fails too.
12. Remove the test membership, or keep yourself in the group you will actually use.

## 9. When a service is added

The permission sets grant data reads only through conventions, so most services need no change here.

- **Database inspection.** Create a read-only database user. Store its credentials in Secrets Manager under a name starting with `readonly/`, for example `readonly/samiksha-db`. Use the default `aws/secretsmanager` key: Read-only and Developer can then read the secret with no KMS grant. Testers reach a private database by forwarding a port through an instance tagged `db-tunnel = true` (section 7).
- **ECS exec for Developers.** The ECS service needs `enableExecuteCommand = true`. Its task role needs the `ssmmessages:CreateControlChannel`, `CreateDataChannel`, `OpenControlChannel` and `OpenDataChannel` actions. The Developer uses the Session Manager plugin installed for SSH.
- **Documents in S3 that testers verify.** Edit the `Read-only` permission set's inline policy, and add a statement for the service's bucket:
  ```json
  {
    "Sid": "SamikshaDocumentsRead",
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetObject"],
    "Resource": ["arn:aws:s3:::<bucket>", "arn:aws:s3:::<bucket>/*"]
  }
  ```
  If the bucket uses SSE-KMS with a customer-managed key, also allow `kms:Decrypt` on that key, with the condition `"kms:ViaService": "s3.ap-south-1.amazonaws.com"`.
- **Saving a permission set edit.** The change reaches accounts only when the permission set is provisioned again. The console offers this after the save. Otherwise use Permission sets → the set → **Update in all accounts**.

## Open items

- How logs are collected is not decided. The permission sets assume CloudWatch Logs. Another store, such as a self-hosted stack, would need its own access.
- Moving the existing admins from their IAM users to `samanvay-admins` is optional and done one person at a time. Until then, `tofu` work continues through `tanuh-cli-*` and `OrganizationAccountAccessRole`.
- If the Tanuh accounts leave the Samanvay Ops organization, Identity Center access to them ends immediately. Tanuh's users would need new access in Tanuh's own organization.
