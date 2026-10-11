#!/usr/bin/env bash
# Remove the MX install on the app VM: stop services, kill leftovers, delete
# MX_HOME and extra leftover paths. Ansible must only call this after the
# rollback backup is confirmed in JFrog; BACKUP_REF records which one.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/mx.sh
source "${SCRIPTS_ROOT}/app/lib/mx.sh"

usage() {
  cat <<'EOF'
Usage: mx_cleanup_app.sh --backup-ref <jfrog-path> [--dry-run] [--force] [--run-id ID] [--mx-home DIR]

Deletes MX_HOME and MX_EXTRA_CLEAN_PATHS. Nothing to delete -> RESULT status=ok.
Guards:
  - BACKUP_REF (JFrog path of the confirmed rollback backup) is required; it is
    logged, not verified (Ansible owns that check)
  - MX_HOME and every extra path must sit under MX_ALLOWED_PREFIXES
  - MX_HOME must contain MX_HOME_MARKER unless --force
Inputs: RUN_ID, MX_HOME, BACKUP_REF, MX_EXTRA_CLEAN_PATHS (space-separated,
globs allowed, e.g. "/opt/murex/patch-work /opt/murex/tmp/*").
EOF
}

: "${BACKUP_REF:=}"
: "${MX_EXTRA_CLEAN_PATHS:=}"
SCRIPT_VARS=("${MX_VARS[@]}" BACKUP_REF MX_EXTRA_CLEAN_PATHS)
init_script mx_cleanup_app "$@"
mx_require_home_var
require_vars BACKUP_REF
acquire_lock mx-app
log_info "cleanup authorised by rollback backup ${BACKUP_REF}"

if [[ -e "$MX_HOME" && ! -f "${MX_HOME}/${MX_HOME_MARKER}" ]] && ! ((FORCE)); then
  die "${MX_HOME} exists but has no ${MX_HOME_MARKER}; refusing to delete it without --force"
fi
[[ -L "$MX_HOME" ]] && die "${MX_HOME} is a symlink; remove or resolve it by hand"

mx_stop_services

if [[ -e "$MX_HOME" ]]; then
  run_or_die rm -rf --one-file-system -- "$MX_HOME"
  mark_changed
else
  log_info "MX_HOME ${MX_HOME} already absent"
fi

shopt -s nullglob
for pattern in $MX_EXTRA_CLEAN_PATHS; do
  # shellcheck disable=SC2206
  matches=($pattern)
  for p in "${matches[@]}"; do
    # shellcheck disable=SC2086
    assert_safe_path "$p" $MX_ALLOWED_PREFIXES
    run_or_die rm -rf --one-file-system -- "$p"
    mark_changed
  done
done
shopt -u nullglob

result auto "mx_home=${MX_HOME}" "backup_ref=${BACKUP_REF}"
