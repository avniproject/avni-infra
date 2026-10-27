# IAM Identity Center: adding and removing people

How to give a person access to the Tanuh AWS accounts, change it, and take it away. The one-time setup, permission sets and group assignments are in `setup.md` next to this file.

Access portal: `https://samanvay.awsapps.com/start`. Without `/start`, AWS returns 403.

## Before you start

- Only the Samanvay Ops admins do this.
- Sign in to the management account with your IAM user, and set the console region to **ap-south-1**. Identity Center appears empty in any other region.
- This is the production account. Change only IAM Identity Center pages.

Rules:

1. **Access goes through groups.** Never assign a permission set to a user directly.
2. **A person is only in their own organization's groups.** A Tanuh person is only in `tanuh-*` groups and a Samanvay person only in `samanvay-*` groups. The group prefix is the only record of which organization someone belongs to.
3. **Never assign a Tanuh group or the Admin, Developer or Read-only permission set to the management account.** The existing `Billing` assignments there are separate; leave them.
4. **One user per person**, signed up with their own work email. No shared users.

| Group | Role | Accounts |
|---|---|---|
| `samanvay-admins` | Admin | staging, prod |
| `samanvay-developers` | Developer | staging, prod |
| `samanvay-readonly` | Read-only | staging |
| `tanuh-admins` | Admin | staging |
| `tanuh-developers` | Developer | staging |
| `tanuh-readonly` | Read-only | staging |

Read-only is for testers: logs, metrics, read-only database credentials and the S3 documents each service grants. Developer adds SSH, port forwarding through any instance, ECS exec, restarting instances, tasks and databases, and billing. Admin is full access. Tanuh has it on staging only, through `tanuh-admins`.

## Add a person

1. IAM Identity Center → Users → **Add user**.
   - Username: their work email, for example `<name>@<their organization's domain>`
   - Password: **Send an email to this user with password setup instructions**
   - Email, first name, last name, display name
2. Next → add the user to one group (table above). If that group doesn't exist yet, create it, then assign it to its accounts as in `setup.md` section 6.
3. Next → **Add user**.
4. If they will use the CLI, SSH or a database, give them read access to the GitHub repository `TANUH-AI/tanuh-samanvay-infra`, which has the profiles and scripts.
5. Send them the "First sign-in" section below. The invitation email from AWS is valid for 7 days. If it expires: Users → the user → **Reset password** → send an email.
6. After they sign in, the user page shows MFA devices: 1.

## Change a person's role

Users → the user → Groups → remove the old group, then add the new one, within their own organization's groups. Role credentials they already have keep working until they expire (up to 8 hours, or 4 hours for Admin), even across a new sign-in. To pick up the change at once, they run `aws sso logout && aws sso login --sso-session samanvay` and reopen the console from the portal.

## Give a tester access to prod

Testers have staging only. To give one tester prod without giving it to every tester:

1. Once only: create the group `tanuh-readonly-prod` (or `samanvay-readonly-prod`). Assign it to `tanuh-prod` with **Read-only**.
2. Add the tester to that group, and keep them in `tanuh-readonly` for staging.

Never assign `tanuh-readonly` itself to prod. That would give prod to every tester in the group.

## Give a Tanuh person Admin

`tanuh-admins` has Admin on `tanuh-staging`. Adding someone to it gives them full control of that account. When adding any Tanuh user, check the group you picked: `tanuh-admins` sits next to `tanuh-developers` in the list.

1. Agree with the other Samanvay admins before adding someone.
2. Add the person to `tanuh-admins`. They can stay in another `tanuh-*` group too.
3. Giving `tanuh-admins` access to prod is a separate decision by the Samanvay admins.

When they leave the group, or leave altogether, check IAM in `tanuh-staging` for users, access keys and roles they created. Admin can create credentials that outlive Identity Center access. CloudTrail `tanuh-trail` shows who created what.

## Remove a person

1. Users → the user → **Groups** → note their groups, for the record of who had what.
2. Users → the user → **Active sessions** → select all → **End sessions** → type `confirm`. Do this before deleting: once the user is deleted, the console can no longer end their sessions.
3. Users → select the user → **Delete user**.

Deleting a user also removes their group memberships and MFA devices. Ending their sessions signs them out of the access portal and the CLI, so they can't get new credentials. **Credentials they already got for an account keep working until they expire**, which is up to 8 hours, or 4 for Admin. For a normal departure, that is acceptable.

### End their access immediately

Use this when access must stop now, for example a lost laptop or a dispute. Do it after the steps above.

1. IAM Identity Center → Permission sets → the permission set the person had → Inline policy → Edit. Add this statement, with the current time in UTC:
   ```json
   {
     "Sid": "RevokeSessionsBefore20261027T1200Z",
     "Effect": "Deny",
     "Action": "*",
     "Resource": "*",
     "Condition": { "DateLessThan": { "aws:TokenIssueTime": "2026-10-27T12:00:00Z" } }
   }
   ```
2. Save, then **Update in all accounts** to provision it.
3. Repeat for each permission set the person had.

This ends every session of that permission set issued before that time, for everyone. Other users just sign in again. Once the longest session length has passed (8 hours), remove the statement and provision again.

Also check the person's work in the account. A Developer cannot create IAM users or access keys. An Admin can, so after an Admin leaves, review IAM users, access keys and roles created in `tanuh-staging` and `tanuh-prod` since they were given access. CloudTrail `tanuh-trail` records who created what.

## Remove an organization

When a client leaves, for example Tanuh:

1. IAM Identity Center → Groups. Filter by the prefix (`tanuh-`). Note each group and its members.
2. For each member, open the user and check their **Groups** tab. If they are in any group outside that prefix, stop and sort that out first: rule 2 has been broken, and they may be someone else's person.
3. For each member, end their active sessions, then delete them, as in "Remove a person".
4. For each group, remove its account assignments: AWS accounts → the account → the group's assignment → **Remove access**.
5. Delete the groups.
6. If the client's accounts are leaving too, remove the remaining assignments to those accounts (the `samanvay-*` groups). Do that before the accounts leave the organization.
7. To end every session at once, use "End their access immediately" above on each permission set those groups used.

Permission sets are shared by every client, so they stay.

## Lost MFA device or password

- **Password:** the person uses **Forgot password** on the portal sign-in page.
- **MFA device:** Users → the user → **MFA devices** → delete the lost device. At the next sign-in they register a new one. Confirm who is asking, by a channel other than email, before you do this.

## Who has access

Users → each user's **Groups** tab, or Groups → each group's **Users** tab. AWS accounts → each account shows which groups are assigned with which permission set.

Check this whenever someone leaves Samanvay or a client, and confirm that Samanvay Ops still shows only the `Billing` assignments.

## First sign-in

Send this to a new user.

> You've been given access to the Tanuh AWS accounts.
>
> 1. Open the email from AWS ("Invitation to join AWS IAM Identity Center") and accept it within 7 days. Choose a password.
> 2. Register an MFA device when asked: an authenticator app or a security key. MFA is asked for at every sign-in.
> 3. Sign in at https://samanvay.awsapps.com/start. You'll see the accounts and roles you have. Click a role to open the console.
>
> Then set up the AWS CLI, SSH and database access with `docs/access/README.md` in the `TANUH-AI/tanuh-samanvay-infra` repository. Ask the person who added you for access to it if you don't have it.
