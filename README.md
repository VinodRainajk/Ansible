# Murex automation

Ansible automation for building and patching Murex MX.3 environments
(dev, qa, uat, preprod). Each environment is a Linux Murex app VM plus a
dedicated Oracle DB host. Credentials come from a vault-encrypted file or from
CyberArk, and artifacts come from JFrog.

**What works today:** the repo skeleton, **Section 0: Preflight** and
**Section 1: Credentials**. Playbooks for later sections (validate, rebuild,
patch, promote-gold) already exist. They run preflight and credentials, then
stop with `not implemented yet` and exit code 2.

---

## 1. Install (control node)

The control node is the Linux machine you run Ansible from. It needs SSH
access to the app VM and the Oracle host.

```bash
# Python 3.10+ and ansible-core 2.16 to 2.21
python3 --version
python3 -m pip install --user 'ansible-core>=2.16,<2.22'
export PATH="$HOME/.local/bin:$PATH"     # add this to ~/.bashrc
ansible --version

# sshpass is needed only if you log in to the hosts with a password, not an SSH key
sudo dnf install -y sshpass     # or: sudo apt-get install -y sshpass

# Collections (cyberark.pas, community.general, ansible.posix), installed
# into ./collections, which ansible.cfg already points to
git clone <this repo> murex-ansible && cd murex-ansible
ansible-galaxy collection install -r collections/requirements.yml -p collections
```

Run every command below from the repo root, where `ansible.cfg` is.

## 2. Fill in the placeholders

Every value you must change contains `CHANGE-ME` or `CHANGE_ME`. To list them:

```bash
grep -rn 'CHANGE[-_]ME' inventories/dev
```

Do this for each environment you use (`inventories/dev`, `qa`, `uat`, `preprod`).

| File | What to set |
| --- | --- |
| `inventories/<env>/hosts.yml` | The real app VM under `murex_app` and the Oracle host under `oracle_db`. Uncomment `ansible_host:` only if the name does not resolve. |
| `inventories/<env>/group_vars/all/main.yml` | `log_base_dir` (default `/var/log/murex-ansible/<env>`), the staging dirs, and the disk thresholds. When `use_cyberark: true`, also `cyberark_ccp_url`, `cyberark_app_id`, and the `safe` / `object` values in `cyberark_accounts`. |
| `inventories/<env>/group_vars/murex_app.yml` | `script_run_user` / `script_run_group`: the OS user the Murex scripts run as (assumed `murex`/`murex`). |
| `inventories/<env>/group_vars/oracle_db.yml` | The same for the Oracle host (assumed `oracle`/`oinstall`). |
| `inventories/<env>/group_vars/all/credentials.yml` | Only when `use_cyberark: false`. See below. |

### Credentials file (`use_cyberark: false`, the default)

```bash
cd inventories/dev/group_vars/all
cp credentials.yml.example credentials.yml
vi credentials.yml                      # replace every CHANGE_ME
ansible-vault encrypt credentials.yml   # choose a vault password
cd -
```

- `credentials.yml` is git-ignored. Never commit it, even encrypted, unless
  your team agrees to.
- A plain (unencrypted) file also works. Every run then logs a WARN; use it
  only on a throwaway test VM.
- To change the file later: `ansible-vault edit inventories/dev/group_vars/all/credentials.yml`.

It holds eight values. The playbooks use the same names whether the values
come from the file or from CyberArk:

| Variable | Used for |
| --- | --- |
| `mx_ssh_user` / `mx_ssh_password` | SSH login and sudo password on the Murex app VM (`""` password = SSH key) |
| `ora_ssh_user` / `ora_ssh_password` | The same on the Oracle host |
| `db_admin_user` / `db_admin_password` | Oracle account for expdp/impdp and schema work (later sections) |
| `jfrog_user` / `jfrog_token` | JFrog downloads and uploads (later sections) |

### CyberArk (`use_cyberark: true`)

1. In `group_vars/all/main.yml`, set `use_cyberark: true`, then
   `cyberark_ccp_url`, `cyberark_app_id`, and the `safe` / `object` of each
   entry in `cyberark_accounts`.
2. If CCP needs a client certificate, set `cyberark_client_cert` and
   `cyberark_client_key` (paths on the control node).
3. No `credentials.yml` is needed. Preflight runs before credentials are
   fetched, so in this mode it connects to the hosts as **you** (`$USER`)
   with your SSH key. Make sure key login and sudo work for your account.

### Log directory

Create `log_base_dir` once on the control node and on both hosts:

```bash
sudo mkdir -p /var/log/murex-ansible/dev && sudo chown "$USER" /var/log/murex-ansible/dev
```

On the hosts, preflight creates `script_logs/` itself, through sudo.

## 3. Check the control node

```bash
scripts/common/preflight/check_control_node.sh --env dev
# with a vault-encrypted credentials.yml, this also checks the vault password:
scripts/common/preflight/check_control_node.sh --env dev --vault-password-file ~/.vault_pass_dev
```

It checks the following without touching any host:

- the ansible-core and Python versions
- that the collections are installed
- the repo layout
- that the inventory parses and has no `CHANGE-ME` host left
- the credentials file, or the CyberArk settings
- that `run_logs/` can be written
- free disk space
- `sshpass`

Each check logs one line. The script exits 1 and lists every failed check.
Fix them and run it again until it ends with `RESULT status=ok`.

## 4. Run preflight, then credentials

```bash
ansible-playbook -i inventories/dev playbooks/preflight.yml --ask-vault-pass
ansible-playbook -i inventories/dev playbooks/credentials.yml --ask-vault-pass
```

Leave out `--ask-vault-pass` when `credentials.yml` is plain or
`use_cyberark: true`. You can use `--vault-password-file <file>` instead.

**`preflight.yml`** checks:

- On the control node: the Ansible version and that the inventory has app and
  DB hosts. It also creates `<log_base_dir>/run_logs/<run_id>/`.
- On every host: SSH, sudo to root, sudo to the script user,
  `<log_base_dir>/script_logs/<run_id>/` (writable by the script user), the
  staging dir, and free disk space.

All hosts are checked, even when one fails. The run then fails, naming the
failed hosts and the check that failed on each.

**`credentials.yml`** runs preflight, then loads the eight credentials:

- It fails if any value is missing or still `CHANGE_ME`. The error lists
  names only, never values.
- In CyberArk mode, it logs the CCP connection and each object fetched,
  without values.
- It ends with `credentials cleared`, which is logged even when the run fails.

Every other playbook starts the same way: preflight first, then credentials.

## Logs

Each run has a `run_id`: `<env>-<playbook>-<YYYYMMDD-HHMMSS>` (UTC), for
example `dev-preflight-20261011-140501`. To set your own, pass `-e run_id=...`.

Every log line has this format:

```
<ISO-8601 UTC ts> <INFO|WARN|ERROR> <run_id> <step> <message>
2026-10-11T14:05:02Z INFO dev-preflight-20261011-140501 preflight host=mx-app-dev-01 check=all ok login=svc_mx script_user=murex free_mb_logs=8123 free_mb_stage=40211
```

| Where | Path |
| --- | --- |
| Control node, Ansible run log | `<log_base_dir>/run_logs/<run_id>/run.log` |
| App VM / Oracle host, script logs | `<log_base_dir>/script_logs/<run_id>/<step>.log` |
| Fallback when `run_logs` can't be created | `/tmp/murex-ansible-preflight-<run_id>.log`; the run then fails with a `sudo mkdir`/`chown` hint |

The log dirs are mode 0755, so the Splunk Universal Forwarder can read them.
Passwords and tokens never appear in any log.

## Repo layout

```
ansible.cfg                      # roles path, ./collections, ssh settings, profile_tasks timing
collections/requirements.yml
inventories/<env>/               # dev, qa, uat, preprod
  hosts.yml                      # murex_app and oracle_db groups
  group_vars/all/main.yml        # env settings: logs, staging, CyberArk
  group_vars/all/credentials.yml.example
  group_vars/murex_app.yml
  group_vars/oracle_db.yml
playbooks/
  preflight.yml                  # Section 0
  credentials.yml                # Section 0 + Section 1
  validate.yml rebuild.yml patch.yml promote-gold.yml   # orchestrators (stubs)
  app/{validate,rebuild,patch}.yml                      # app tier (stubs)
  db/{validate,rebuild,patch}.yml                       # DB tier (stubs)
  common/                        # shared plays: load credentials, end run, not-implemented
roles/
  run_logging/                   # run_id, run log dir, log line helper
  preflight/                     # Section 0
  credentials/                   # Section 1 (file or CyberArk)
  jfrog_fetch/ compat_check/ app_*/ db_*/   # README only, built in later sections
scripts/                         # sample support-team scripts; see scripts/README.md
  common/lib/ common/preflight/check_control_node.sh
  app/{lib,lifecycle,backup,cleanup,install,config,patch}/
  db/{lib,backup,cleanup,import}/
tests/
  scripts/smoke.sh               # script tests with fake Murex/Oracle binaries
  ansible/                       # integration test for Sections 0 and 1
```

Differences from the plan:

- Env settings live in `group_vars/all/main.yml`, not `group_vars/all.yml`.
  Ansible ignores `all.yml` when a `group_vars/all/` folder exists, and that
  folder is needed for `credentials.yml`.
- The plan's `cyberark_creds` role is named `credentials`, because it reads
  either the file or CyberArk.

## Tests

```bash
tests/scripts/smoke.sh                      # the support scripts; needs no root, Murex or Oracle

ansible-lint                                # production profile
for p in playbooks/*.yml playbooks/*/*.yml; do
  ansible-playbook -i inventories/dev "$p" --syntax-check
done
shellcheck -x scripts/*/*/*.sh tests/*/*.sh

# Integration test for Sections 0 and 1 on this machine. Two local sshd
# ports stand in for the app VM and the Oracle host, and a mock CCP stands
# in for CyberArk. Setup needs sudo and is for a disposable test VM only.
tests/ansible/setup_local_hosts.sh
tests/ansible/run_local.sh
```
