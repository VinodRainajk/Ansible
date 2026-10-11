# Sample Murex / Oracle support scripts

These scripts **stand in for the support team's real Murex and Oracle shell
scripts**, which cannot be shared. They follow the script contract in the
Murex Ansible plan, so the Ansible roles can be built and tested against them now.
Later, each one is swapped for (or mapped onto) the team's real script.

Everything below marked **Assumption** is a guess. Each one is a question for
the support team: "what does your real script do here?"

## Scripts

| Script | Host | Plan step | What it does |
| --- | --- | --- | --- |
| `app/lifecycle/mx_status.sh` | app VM | validate, smoke | Per-service state; `--expect running\|stopped` turns it into an assertion |
| `app/lifecycle/mx_stop.sh` | app VM | backup, cleanup, patch | Clean stop command, then TERM, then KILL leftovers |
| `app/lifecycle/mx_start.sh` | app VM | restore, patch | Start command, wait until every service is up, optional health command |
| `app/backup/mx_backup_app.sh` | app VM | safety + candidate backup | `tar.gz` of MX home + `.sha256` + `.manifest` |
| `app/cleanup/mx_cleanup_app.sh` | app VM | cleanup | Stop, kill leftovers, delete MX home and extra leftover paths |
| `app/install/mx_restore_app.sh` | app VM | restore from gold | Verify checksum, extract to staging, move into place |
| `app/config/mx_config_overlay.sh` | app VM | config migration | Copy env-specific rendered files over MX home; fail if other envs' hostnames remain |
| `app/patch/mx_apply_patch.sh` | app VM | patch | Back up overwritten files, overlay `files/`, run `sql/`, run `patch.sh`, record patch id |
| `db/backup/db_export.sh` | DB host | safety + candidate backup | `expdp` of one schema + per-file `.sha256` + manifest |
| `db/cleanup/db_cleanup_schema.sh` | DB host | cleanup | Kill sessions, then drop all objects (default) or drop the user |
| `db/import/db_import.sh` | DB host | restore from gold | Verify dumps, `impdp` with optional remap, recompile, count invalid objects |
| `common/lib/common.sh` | both | — | Logging, args, dry-run, traps, lock, checksums, path guards |
| `app/lib/mx.sh` | app VM | — | Service detection, stop/start helpers, run-as-MX-user |
| `db/lib/oracle.sh` | DB host | — | sqlplus/datapump helpers that keep the password off argv |
| `common/preflight/check_control_node.sh` | control node | Section 0 | Checks the control node before the first playbook run (see the root README) |

Paths are relative to `scripts/`. Each script finds its libraries relative to
its own location (`scripts/common/lib`, `scripts/<tier>/lib`), so keep the
tree intact when copying it. Each script has `--help`.

## Contract (all scripts)

- **Inputs** come from environment variables. Every input can also be passed
  as a long flag with the same name: `--mx-home /opt/murex/mx3` sets `MX_HOME`.
  Unknown flags are rejected.
- **Secrets:** `DB_PASSWORD` is read from the environment only. Ansible sets it
  from CyberArk with `no_log: true`. Passing `--db-password` is rejected.
  The password never goes on a command line: sqlplus gets it on stdin, and
  expdp/impdp get it from a mode-0600 parfile that is deleted on exit. Any
  log message containing it is masked as `****`.
- **Log format:** one line per event,
  `<ISO-8601 UTC ts> <INFO|WARN|ERROR> <run_id> <step> <message>`.
  Lines go to stdout and to `$LOG_DIR/<step>.log`. Ansible sets `LOG_DIR` to
  `<log_base_dir>/script_logs/<run_id>`; standalone it defaults to
  `/var/log/murex-ansible/script_logs/<RUN_ID>`. If that path is not
  writable, the script logs to `LOG_FALLBACK_FILE` if set, otherwise
  `$TMPDIR/murex-ansible/script_logs/<RUN_ID>/<step>.log`, and logs a WARN.
  Command output (stop/start scripts, expdp, impdp, sqlplus) is logged line by
  line with a `  | ` prefix.
- **Exit codes:** 0 on success. Non-zero on failure, always after an ERROR
  line. Codes used: 1 general failure, 2 bad input, 3 lock held by another run,
  4 checksum problem, 5 not enough disk space (`db_import.sh` also uses 5 for
  impdp "completed with errors" when `IMPDP_STRICT=1`), 6 sqlplus error.
  Otherwise the code is passed through from the failing tool.
- **Changed vs ok:** a successful run ends with
  `RESULT status=changed ...` or `RESULT status=ok ...`, plus key=value
  details such as the archive path and its sha256. In Ansible:
  `changed_when: "'RESULT status=changed' in result.stdout"`.
- **Re-runs:** every script checks whether its work is already done first:
  - same `RUN_ID` backup or export that verifies
  - MX home already restored from the same sha256
  - patch id already in `applied.list`
  - schema already empty
  - import marker for the same dump checksums
- **`--dry-run`:** read-only checks still run (process state, sqlplus
  `select`s, checksums), so a dry run is a real pre-check. Every mutating
  command is logged as `DRY-RUN would run: ...` and skipped.
- **Never interactive:** no prompts. `sudo -n` only. `set -euo pipefail` plus
  an ERR trap that logs the failing command and line.
- **One at a time:** app scripts share the `mx-app` lock, and DB scripts lock
  on `db-<schema>`. Both use `flock` in `LOCK_DIR` (default `/tmp`). A second
  concurrent run exits with code 3. `mx_status.sh` takes no lock.
- **Guard rails:**
  - Delete and extract paths must sit under `MX_ALLOWED_PREFIXES`, can't
    contain `..`, and must be at least two levels deep.
  - Cleanup scripts require `BACKUP_REF`, the JFrog path of the rollback
    backup. They log it but don't check JFrog; enforcing backup-before-cleanup
    stays in Ansible.
  - `db_cleanup_schema.sh` also requires `CONFIRM_SCHEMA` to equal
    `DB_SCHEMA`, and refuses Oracle-maintained schemas and the connecting account.

### Common inputs

| Variable | Default | Used by |
| --- | --- | --- |
| `RUN_ID` | **required**; `<env>-<playbook>-<YYYYMMDD-HHMMSS>` | all |
| `LOG_DIR` | `/var/log/murex-ansible/script_logs/<RUN_ID>` | all |
| `LOCK_DIR` | `/tmp` | all |
| `DRY_RUN` / `--dry-run` | `0` | all |
| `FORCE` / `--force` | `0` | backup (hot backup), cleanup (no marker), restore (non-empty target) |

## Assumptions to map to the real scripts

### Murex app VM

| Item | Assumed value | Variable to change it |
| --- | --- | --- |
| MX home | `/opt/murex/mx3` (no default; always passed) | `MX_HOME` |
| Allowed parent for MX paths | `/opt/murex` | `MX_ALLOWED_PREFIXES` (space-separated) |
| Runtime user / group | `murex` / `murex` | `MX_USER`, `MX_GROUP` |
| How scripts run | As `MX_USER`, or as a sudoer who can `sudo -n -u murex` | — |
| Service names | `fileserver xmlserver launcher` | `MX_SERVICES` |
| How a service is detected | A process owned by `MX_USER` whose command line contains both `MX_HOME` and the service name (e.g. `java -Dmx.home=/opt/murex/mx3 -Dmx.service=fileserver`) | `MX_SERVICES` (patterns are `MX_HOME.*<name>`) |
| Start command | `./launchall.sh`, run from `MX_HOME`, returns once services are launched | `MX_START_CMD` |
| Stop command | `./stopall.sh`, run from `MX_HOME` (many sites use `launchmxj.app -killall` or similar; map it here) | `MX_STOP_CMD` |
| Process manager | Murex's own scripts, **not** systemd units | — |
| Timeouts | start 600 s, stop 300 s, then TERM, 30 s grace, then KILL | `MX_START_TIMEOUT`, `MX_STOP_TIMEOUT`, `MX_KILL_GRACE` |
| Health check after start | none | `MX_HEALTH_CMD` (e.g. a ping/login script) |
| "Is this an MX home?" marker | `launchall.sh` at the MX home root | `MX_HOME_MARKER` |
| MX version file | `version.txt` at the MX home root (first line) | `MX_VERSION_FILE` |
| Backup location | `/opt/murex/backups/mx_home_<RUN_ID>.tar.gz` (outside MX home); Ansible uploads it to JFrog | `BACKUP_DIR` |
| Excluded from the tarball | `./logs ./tmp` | `BACKUP_EXCLUDES` |
| Tarball layout | Contents relative to MX home (`tar -C $MX_HOME .`), so a gold copy restores to any path | — |
| Backup consistency | Cold: services stopped first (`--force` allows hot) | — |
| Extra leftovers to clean | none | `MX_EXTRA_CLEAN_PATHS` (globs, must be under `MX_ALLOWED_PREFIXES`) |
| Patch archive layout | `.tar.gz`/`.tgz`/`.zip` with `files/` (overlaid onto MX home), optional `sql/*.sql`, optional `patch.sh` hook; may sit inside one top-level folder | — |
| Patch DB scripts | Run from the app VM with the Oracle client: `sqlplus` to `DB_TNS` as `DB_USER` | `DB_TNS`, `DB_USER`, `DB_PASSWORD` |
| Patch bookkeeping | `MX_HOME/.patches/applied.list` (tab-separated: id, run id, time, sha256); per-patch backup in `MX_HOME/.patches/<id>/` | — |
| Patch work dir | `<parent of MX_HOME>/patch-work/<id>-<run_id>`, removed on exit | `PATCH_WORK_DIR` |
| Config overlay input | A directory, already rendered by Ansible templates, that mirrors MX home paths | `OVERLAY_DIR` |
| Files scanned for other envs' hostnames | `*.xml *.properties *.cfg *.conf *.ini *.sh` under MX home (skips `logs`, `.patches`, `.config-backup`) | `CONFIG_SCAN_GLOBS`, `FORBIDDEN_PATTERNS` |
| Restore marker | `MX_HOME/.mx_restore` (archive sha256) | — |

### Oracle DB host

| Item | Assumed value | Variable to change it |
| --- | --- | --- |
| OS user | `oracle` (scripts are run as it) | — |
| Oracle home | `/u01/app/oracle/product/19.0.0/dbhome_1` | `ORACLE_HOME` |
| SID | no default; e.g. `MXDEV`, `MXQA`, `MXUAT`, `MXPRE` | `ORACLE_SID` |
| Connection | Local bequeath through `ORACLE_SID`, or a TNS alias if `DB_TNS` is set | `DB_TNS` |
| Connecting account | A CyberArk-managed DBA-style account (e.g. `MX_DBA`), **not** the schema owner. It needs `DATAPUMP_EXP_FULL_DATABASE`, `DATAPUMP_IMP_FULL_DATABASE`, `SELECT` on `DBA_*`/`GV$SESSION`, `ALTER SYSTEM`, `ALTER USER`, `CREATE ANY DIRECTORY`, plus `DROP USER` for `drop_user` mode | `DB_USER`, `DB_PASSWORD` |
| Password rule | Must not contain a double quote | — |
| Murex schema | One schema per run, e.g. `MUREX`; datamart or other schemas are separate runs | `DB_SCHEMA` |
| Datapump directory | Oracle directory `MX_DP_DIR` → `/u01/app/oracle/dpdump/murex` (created or repointed if needed) | `DP_DIR_NAME`, `DP_DIR_PATH` |
| Dump naming | `<schema>_<RUN_ID>_NN.dmp`, `.sha256` per file, `<schema>_<RUN_ID>.manifest`, `.exp.log` / `.imp.log` | — |
| Export options | `parallel=1`, `compression=METADATA_ONLY` (`ALL` needs the Advanced Compression licence), `flashback_time=systimestamp` for a consistent dump | `EXPDP_PARALLEL`, `EXPDP_COMPRESSION`, `EXPDP_CONSISTENT` |
| Schema cleanup | `drop_objects` (default) keeps the user, grants, quotas and password; `drop_user` drops the user cascade so impdp recreates it | `DB_CLEANUP_MODE` |
| Cleanup gaps | AQ queue tables, scheduler jobs and DB links are not handled specially. If anything remains, the script lists it and fails | — |
| Import options | `table_exists_action=REPLACE`; remap when the dump's schema differs; optional tablespace remap | `TABLE_EXISTS_ACTION`, `SOURCE_SCHEMA`, `REMAP_TABLESPACE`, `IMPDP_PARALLEL` |
| impdp rc=5 ("completed with errors") | WARN with the ORA- count (gold imports often raise harmless `ORA-31684`); `IMPDP_STRICT=1` makes it fail | `IMPDP_STRICT` |
| After import | `DBMS_UTILITY.COMPILE_SCHEMA`; more than `MAX_INVALID` (0) invalid objects is a WARN | `MAX_INVALID` |
| Import marker | `DP_DIR_PATH/.import_<schema>_<RUN_ID>.done` (fingerprint of dump checksums) | — |

### What stays in Ansible, not in these scripts

- CyberArk lookups: the scripts only read `DB_PASSWORD` from the environment.
- JFrog download and upload: the scripts read staged files and write local
  files plus checksums.
- Checking that the rollback backup exists in JFrog before cleanup. The
  scripts only require `BACKUP_REF`.
- Rendering config templates for `mx_config_overlay.sh`.
- Version-compatibility checks, rebuild scope and run summaries.

### Deploying them with Ansible

The scripts source their `lib/*.sh` files. `ansible.builtin.script` copies
only one file, so copy the whole `scripts/` tree to the target first (to
`scripts_root` from `group_vars/all/main.yml`, with `ansible.builtin.copy`)
and call the scripts with `ansible.builtin.command`. That copy step is built
in a later section; Sections 0 and 1 don't run any of these scripts on the
hosts. Long steps are `db_export`, `db_import`, `mx_backup_app`,
`mx_restore_app` and `mx_apply_patch`; run them with `async`/`poll`.

```yaml
- name: Export Murex schema
  ansible.builtin.command:
    argv: ["{{ scripts_root }}/db/backup/db_export.sh", "--dry-run"]
  environment:
    RUN_ID: "{{ run_id }}"
    LOG_DIR: "{{ script_log_dir }}/{{ run_id }}"
    ORACLE_SID: "{{ oracle_sid }}"
    DB_USER: "{{ db_user }}"
    DB_PASSWORD: "{{ db_password }}"
    DB_SCHEMA: "{{ db_schema }}"
  no_log: true
  async: 7200
  poll: 30
  register: export_result
  changed_when: "'RESULT status=changed' in export_result.stdout"
```

`no_log: true` also hides stdout. To keep the script log visible, fetch
`LOG_DIR/<step>.log` (which never contains the password) into the run folder.

## Testing without Murex or Oracle

Run from the repo root:

```bash
tests/scripts/smoke.sh          # 51 checks, takes a few seconds; no root, sudo, Murex or Oracle needed
KEEP=1 tests/scripts/smoke.sh   # keep the temp dir and logs for inspection
shellcheck -x scripts/*/*/*.sh tests/scripts/*.sh tests/scripts/fakes/bin/* tests/scripts/fakes/mx_home/*.sh
```

`tests/scripts/fakes/` provides:

- fake `sqlplus`, `expdp` and `impdp` that keep a little state on disk and
  check the parfile is 0600 and the password is not on argv
- a fake MX home whose `launchall.sh` starts processes that look like the
  assumed MX JVMs

The suite runs every script, including dry runs, re-runs, guard-rail
rejections, a forbidden-hostname failure and impdp rc=5 handling. It then
checks that every log line matches the format and that the password never
appears in any log.
