# Laptop kit: Avni servers and databases over Session Manager

Run once: `sh configure/laptop/install.sh`. It adds your AWS sign-in profiles, makes a laptop key used only for this, routes the usual server names through Session Manager, and installs `avni-db`.

Daily:
- `ssh avni-staging`, `scp file avni-prerelease:/tmp/`, playbooks and IntelliJ SSH work under the old names. When your sign-in has lapsed, a browser tab opens.
- `avni-db up readcopy` opens the production read copy on `localhost:15432`. `avni-db up staging prerelease` opens those on 15433 and 15434. `avni-db status`, `avni-db down`.

What you can reach depends on your tiles at https://samanvay.awsapps.com/start. The staff guide "How to reach AWS: the vault, servers and deploys" has the details and screenshots.

| File | What it is |
|---|---|
| `avni.conf` | SSH config: server names to instances, through Session Manager |
| `avni-ssm-proxy.sh` | Pushes your key for 60 seconds, then opens the Session Manager SSH session |
| `avni-db` | Opens database tunnels on fixed local ports |
| `install.sh` | One-time setup; `--check` reports what is missing |
