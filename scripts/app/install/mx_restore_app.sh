#!/usr/bin/env bash
# Restore MX_HOME from a tarball (gold copy or rollback) staged by Ansible.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/mx.sh
source "${SCRIPTS_ROOT}/app/lib/mx.sh"

usage() {
  cat <<'EOF'
Usage: mx_restore_app.sh --archive FILE [--archive-sha256 HEX] [--dry-run] [--force] [--run-id ID] [--mx-home DIR]

Extracts ARCHIVE (made by mx_backup_app.sh: contents relative to MX_HOME) into
a staging dir next to MX_HOME, checks for MX_HOME_MARKER, then moves it into place.
  - MX_HOME already restored from the same archive sha256 -> RESULT status=ok
  - MX_HOME non-empty -> fail (run mx_cleanup_app.sh), unless --force, which
    moves the old tree to MX_HOME.pre-restore-<RUN_ID> (not deleted)
Checksum: ARCHIVE_SHA256, else ARCHIVE.sha256; REQUIRE_CHECKSUM=1 (default)
fails when neither exists.
EOF
}

: "${ARCHIVE:=}"
: "${ARCHIVE_SHA256:=}"
: "${REQUIRE_CHECKSUM:=1}"
SCRIPT_VARS=("${MX_VARS[@]}" ARCHIVE ARCHIVE_SHA256 REQUIRE_CHECKSUM)
init_script mx_restore_app "$@"
mx_require_home_var
require_vars ARCHIVE
acquire_lock mx-app

verify_artifact "$ARCHIVE" "$ARCHIVE_SHA256" "$(as_bool "$REQUIRE_CHECKSUM" && echo 1 || echo 0)"
sum=$(sha256_of "$ARCHIVE")
marker="${MX_HOME}/.mx_restore"

if [[ -f "$marker" ]] && grep -qx "sha256=${sum}" "$marker"; then
  log_info "MX_HOME already restored from this archive (sha256=${sum})"
  result ok "mx_home=${MX_HOME}" "sha256=${sum}"
fi

mx_probe
[[ "$MX_STATE" == stopped ]] || die "MX services are ${MX_STATE}; stop them before restoring"

parent=$(dirname "$MX_HOME")
staging="${MX_HOME}.restore-${RUN_ID}"
run_or_die mkdir -p "$parent"
if ! ((DRY_RUN)); then
  need_kb=$(( $(gzip -l "$ARCHIVE" | awk 'NR==2{print $2}') / 1024 + 1 ))
  require_free_kb "$parent" "$need_kb" "extracted MX home"
fi

[[ -e "$staging" ]] && run_or_die rm -rf -- "$staging"
cleanup_on_exit "$staging"
run_or_die mkdir -p "$staging"
run_or_die tar -C "$staging" -xzpf "$ARCHIVE"
if ! ((DRY_RUN)) && [[ ! -f "${staging}/${MX_HOME_MARKER}" ]]; then
  die "archive does not look like an MX home (no ${MX_HOME_MARKER} at its root)"
fi

if [[ -e "$MX_HOME" ]]; then
  if [[ -z "$(ls -A "$MX_HOME")" ]]; then
    run_or_die rmdir -- "$MX_HOME"
  elif ((FORCE)); then
    aside="${MX_HOME}.pre-restore-${RUN_ID}"
    log_warn "MX_HOME not empty; moving it aside to ${aside} (remove it by hand when no longer needed)"
    run_or_die mv -- "$MX_HOME" "$aside"
  else
    die "MX_HOME ${MX_HOME} is not empty; run mx_cleanup_app.sh first or pass --force"
  fi
fi

run_or_die mv -- "$staging" "$MX_HOME"
mx_chown "$MX_HOME"
if ((DRY_RUN)); then
  log_info "DRY-RUN would write ${marker}"
else
  printf 'run_id=%s\narchive=%s\nsha256=%s\nrestored_utc=%s\n' \
    "$RUN_ID" "$(basename "$ARCHIVE")" "$sum" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker"
fi
mark_changed
result auto "mx_home=${MX_HOME}" "sha256=${sum}"
