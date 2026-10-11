#!/usr/bin/env bash
# End-to-end smoke test of every support script against fake Murex and Oracle
# binaries (tests/scripts/fakes). Needs no Murex, Oracle, root or sudo.
#   tests/scripts/smoke.sh            run the suite
#   KEEP=1 tests/scripts/smoke.sh     keep the temp dir for inspection
# ok() and bad() always return 0, so "cond && ok || bad" is safe here.
# shellcheck disable=SC2015
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S=$(cd "$HERE/../../scripts" && pwd)
FAKES="$HERE/fakes"

T=$(mktemp -d)
cleanup() {
  pkill -f -- "-Dmx.home=${T}/" 2>/dev/null || true
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept ${T}"; else rm -rf "$T"; fi
}
trap cleanup EXIT

RUN_ID="dev-rebuild-$(date -u +%Y%m%d-%H%M%S)"
export RUN_ID
export TMPDIR="$T"
unset LOG_DIR
LOGS="$T/murex-ansible/script_logs"
export LOCK_DIR="$T"
export MX_ALLOWED_PREFIXES="$T/murex"
export MX_HOME="$T/murex/mx3"
export MX_USER MX_GROUP
MX_USER=$(id -un)
MX_GROUP=$(id -gn)
export MX_STOP_TIMEOUT=10 MX_START_TIMEOUT=20 MX_KILL_GRACE=1
export BACKUP_DIR="$T/murex/backups"
export ORACLE_HOME="$FAKES" ORACLE_SID=MXDEV DB_USER=mx_dba DB_SCHEMA=MUREX
export DB_PASSWORD='s3cr3t-Pa55!'
export DP_DIR_PATH="$T/dpdump"
export FAKE_ORA_STATE="$T/ora" FAKE_EXPECT_NO_ARG="$DB_PASSWORD"

pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

# expect <rc> <status-or-"-"> <description> -- cmd...
expect() {
  local want_rc=$1 want_status=$2 desc=$3
  shift 4
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [[ $rc != "$want_rc" ]]; then
    bad "$desc (rc=$rc, want $want_rc)"
    printf '%s\n' "$out" | tail -n 15 | sed 's/^/    /'
    return 0
  fi
  if [[ "$want_status" != - ]] && ! grep -q "RESULT status=${want_status}" <<<"$out"; then
    bad "$desc (no RESULT status=${want_status})"
    printf '%s\n' "$out" | tail -n 15 | sed 's/^/    /'
    return 0
  fi
  if ((want_rc != 0)) && ! grep -q ' ERROR ' <<<"$out"; then
    bad "$desc (failed without an ERROR line)"
    return 0
  fi
  ok "$desc"
}

mkdir -p "$T/murex"
cp -a "$FAKES/mx_home" "$MX_HOME"

echo "== contract"
expect 2 - "missing RUN_ID is rejected" -- env -u RUN_ID "$S/app/lifecycle/mx_status.sh"
expect 2 - "DB_PASSWORD as an argument is rejected" -- "$S/db/backup/db_export.sh" --db-password x
expect 2 - "unknown option is rejected" -- "$S/app/lifecycle/mx_stop.sh" --nope 1
expect 0 - "--help works" -- "$S/app/backup/mx_backup_app.sh" --help
expect 2 - "MX_HOME outside allowed prefix is rejected" -- "$S/app/cleanup/mx_cleanup_app.sh" --mx-home /etc --backup-ref x

echo "== app: start/stop/status"
expect 0 ok "status (stopped)" -- "$S/app/lifecycle/mx_status.sh" --expect stopped
expect 0 changed "dry-run start" -- "$S/app/lifecycle/mx_start.sh" --dry-run
expect 0 ok "status still stopped after dry-run" -- "$S/app/lifecycle/mx_status.sh" --expect stopped
expect 0 changed "start" -- "$S/app/lifecycle/mx_start.sh"
expect 0 ok "start again is a no-op" -- "$S/app/lifecycle/mx_start.sh"
expect 1 - "status --expect stopped fails while running" -- "$S/app/lifecycle/mx_status.sh" --expect stopped
expect 1 - "backup refuses while running" -- "$S/app/backup/mx_backup_app.sh"
expect 0 changed "stop" -- "$S/app/lifecycle/mx_stop.sh"
expect 0 ok "stop again is a no-op" -- "$S/app/lifecycle/mx_stop.sh"

echo "== app: backup/cleanup/restore"
expect 0 changed "backup" -- "$S/app/backup/mx_backup_app.sh"
expect 0 ok "backup again is a no-op" -- "$S/app/backup/mx_backup_app.sh"
archive="$BACKUP_DIR/mx_home_${RUN_ID}.tar.gz"
[[ -f "$archive" && -f "$archive.sha256" && -f "${archive%.tar.gz}.manifest" ]] && ok "archive, sha256 and manifest written" || bad "backup files missing"
expect 2 - "cleanup without BACKUP_REF is rejected" -- "$S/app/cleanup/mx_cleanup_app.sh"
expect 0 changed "dry-run cleanup" -- "$S/app/cleanup/mx_cleanup_app.sh" --backup-ref rollback/dev/x --dry-run
[[ -d "$MX_HOME" ]] && ok "dry-run cleanup left MX_HOME in place" || bad "dry-run cleanup deleted MX_HOME"
expect 0 changed "cleanup" -- "$S/app/cleanup/mx_cleanup_app.sh" --backup-ref "rollback/dev/${RUN_ID}"
expect 0 ok "cleanup again is a no-op" -- "$S/app/cleanup/mx_cleanup_app.sh" --backup-ref "rollback/dev/${RUN_ID}"
expect 4 - "restore rejects a bad checksum" -- "$S/app/install/mx_restore_app.sh" --archive "$archive" --archive-sha256 deadbeef
expect 0 changed "restore" -- "$S/app/install/mx_restore_app.sh" --archive "$archive"
expect 0 ok "restore again is a no-op" -- "$S/app/install/mx_restore_app.sh" --archive "$archive"

echo "== app: config overlay"
mkdir -p "$T/overlay/config"
printf '<cfg><db host="qadb01.corp" sid="MXQA"/></cfg>\n' >"$T/overlay/config/db.xml"
printf 'x={{ unrendered }}\n' >"$T/bad.properties"
expect 0 changed "overlay" -- "$S/app/config/mx_config_overlay.sh" --overlay-dir "$T/overlay" --forbidden-patterns 'devdb01\.corp'
expect 0 ok "overlay again is a no-op" -- "$S/app/config/mx_config_overlay.sh" --overlay-dir "$T/overlay" --forbidden-patterns 'devdb01\.corp'
printf 'peer=devdb01.corp\n' >"$MX_HOME/config/peer.properties"
expect 1 - "overlay fails when another env's host remains" -- "$S/app/config/mx_config_overlay.sh" --overlay-dir "$T/overlay" --forbidden-patterns 'devdb01\.corp'
rm -f "$MX_HOME/config/peer.properties"
mkdir -p "$T/overlay-bad" && cp "$T/bad.properties" "$T/overlay-bad/"
expect 1 - "overlay rejects unrendered templates" -- "$S/app/config/mx_config_overlay.sh" --overlay-dir "$T/overlay-bad"

echo "== app: patch"
mkdir -p "$T/p/files/lib"
printf 'patched\n' >"$T/p/files/version.txt"
printf 'new jar\n' >"$T/p/files/lib/fix.jar"
# shellcheck disable=SC2016  # expanded by the hook, not here
printf '#!/usr/bin/env bash\necho "hook ran for $PATCH_ID in $MX_HOME"\n' >"$T/p/patch.sh"
tar -C "$T/p" -czf "$T/MX-PATCH-0042.tar.gz" .
(cd "$T" && sha256sum MX-PATCH-0042.tar.gz >MX-PATCH-0042.tar.gz.sha256)
expect 0 changed "dry-run patch" -- "$S/app/patch/mx_apply_patch.sh" --patch-file "$T/MX-PATCH-0042.tar.gz" --patch-id MX-PATCH-0042 --dry-run
grep -q patched "$MX_HOME/version.txt" && bad "dry-run patch changed files" || ok "dry-run patch changed nothing"
expect 0 changed "patch" -- "$S/app/patch/mx_apply_patch.sh" --patch-file "$T/MX-PATCH-0042.tar.gz" --patch-id MX-PATCH-0042
expect 0 ok "patch again is a no-op" -- "$S/app/patch/mx_apply_patch.sh" --patch-file "$T/MX-PATCH-0042.tar.gz" --patch-id MX-PATCH-0042
[[ -f "$MX_HOME/.patches/MX-PATCH-0042/backup.tar.gz" ]] && grep -q patched "$MX_HOME/version.txt" && ok "patch applied with pre-patch backup" || bad "patch result wrong"
expect 0 ok "status reports the patch" -- "$S/app/lifecycle/mx_status.sh"

echo "== db: export/cleanup/import"
expect 0 changed "dry-run export" -- "$S/db/backup/db_export.sh" --dry-run
expect 0 changed "export" -- "$S/db/backup/db_export.sh"
expect 0 ok "export again is a no-op" -- "$S/db/backup/db_export.sh"
dump="$DP_DIR_PATH/murex_${RUN_ID}_01.dmp"
[[ -f "$dump" && -f "$dump.sha256" ]] && ok "dump and checksum written" || bad "dump files missing"
expect 2 - "cleanup refuses a mismatched CONFIRM_SCHEMA" -- "$S/db/cleanup/db_cleanup_schema.sh" --confirm-schema OTHER --backup-ref x
expect 2 - "cleanup refuses SYSTEM" -- "$S/db/cleanup/db_cleanup_schema.sh" --db-schema SYSTEM --confirm-schema SYSTEM --backup-ref x
expect 0 changed "schema cleanup (drop_objects)" -- "$S/db/cleanup/db_cleanup_schema.sh" --confirm-schema MUREX --backup-ref "rollback/dev/${RUN_ID}"
expect 0 ok "schema cleanup again is a no-op" -- "$S/db/cleanup/db_cleanup_schema.sh" --confirm-schema MUREX --backup-ref "rollback/dev/${RUN_ID}"
mkdir -p "$T/staged" && cp "$dump" "$dump.sha256" "$T/staged/"
expect 0 changed "import from a staged dump" -- "$S/db/import/db_import.sh" --dump-files "$T/staged/$(basename "$dump")"
expect 0 ok "import again is a no-op" -- "$S/db/import/db_import.sh" --dump-files "$T/staged/$(basename "$dump")"
expect 0 changed "import rc=5 is a WARN by default" -- env FAKE_DP_RC=5 RUN_ID="${RUN_ID}-b" "$S/db/import/db_import.sh" --dump-files "$T/staged/$(basename "$dump")"
expect 5 - "import rc=5 fails with IMPDP_STRICT=1" -- env FAKE_DP_RC=5 IMPDP_STRICT=1 RUN_ID="${RUN_ID}-c" "$S/db/import/db_import.sh" --dump-files "$T/staged/$(basename "$dump")"
expect 0 changed "schema cleanup (drop_user)" -- env DB_CLEANUP_MODE=drop_user "$S/db/cleanup/db_cleanup_schema.sh" --confirm-schema MUREX --backup-ref x

echo "== logs"
if grep -rqF -- "$DB_PASSWORD" "$LOGS"; then bad "DB password found in logs"; else ok "DB password never logged"; fi
badlines=$(cat "$LOGS"/*/*.log | grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z (INFO|WARN|ERROR) [A-Za-z0-9._-]+ [a-z_]+ ' || true)
((badlines == 0)) && ok "every log line matches '<ts> <LEVEL> <run_id> <step> <message>'" || bad "${badlines} malformed log line(s)"
ls "$LOGS/$RUN_ID"/*.log >/dev/null && ok "per-step log files in <log dir>/<run_id>" || bad "no per-step logs"

echo
echo "passed=${pass} failed=${fail}"
((fail == 0))
