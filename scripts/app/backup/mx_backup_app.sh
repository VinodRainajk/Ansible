#!/usr/bin/env bash
# Tar the MX home into BACKUP_DIR with a sha256 and a small manifest.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/mx.sh
source "${SCRIPTS_ROOT}/app/lib/mx.sh"

usage() {
  cat <<'EOF'
Usage: mx_backup_app.sh [--dry-run] [--force] [--run-id ID] [--mx-home DIR] [--backup-dir DIR]

Writes BACKUP_DIR/mx_home_<RUN_ID>.tar.gz (+ .sha256, .manifest).
The archive holds MX_HOME's contents relative to MX_HOME (tar -C MX_HOME .),
so it can be restored to a different path.
MX services must be stopped; --force allows a hot backup (logged as WARN).
Re-running with the same RUN_ID and a valid archive -> RESULT status=ok.
Inputs: RUN_ID, MX_HOME, BACKUP_DIR (default /opt/murex/backups),
BACKUP_EXCLUDES (space-separated, relative to MX_HOME; default "./logs ./tmp"),
MX_VERSION_FILE (relative to MX_HOME; default version.txt).
EOF
}

: "${BACKUP_DIR:=/opt/murex/backups}"
: "${BACKUP_EXCLUDES:=./logs ./tmp}"
: "${MX_VERSION_FILE:=version.txt}"
SCRIPT_VARS=("${MX_VARS[@]}" BACKUP_DIR BACKUP_EXCLUDES MX_VERSION_FILE)
init_script mx_backup_app "$@"
mx_require_home_var
acquire_lock mx-app

BACKUP_DIR=${BACKUP_DIR%/}
[[ "$BACKUP_DIR" == /* ]] || die 2 "BACKUP_DIR must be absolute"
[[ "$BACKUP_DIR/" != "$MX_HOME/"* ]] || die 2 "BACKUP_DIR must be outside MX_HOME"
[[ -f "${MX_HOME}/${MX_HOME_MARKER}" ]] || die "no MX install at ${MX_HOME} (missing ${MX_HOME_MARKER})"

archive="${BACKUP_DIR}/mx_home_${RUN_ID}.tar.gz"
if [[ -f "$archive" ]] && sha256_verify "$archive"; then
  log_info "backup already exists and verifies: ${archive}"
  result ok "archive=${archive}" "sha256=$(sha256_of "$archive")"
fi

mx_probe
if [[ "$MX_STATE" != stopped ]]; then
  ((FORCE)) || die "MX services are ${MX_STATE}; stop them first (or --force for a hot backup)"
  log_warn "taking a hot backup while MX is ${MX_STATE}"
fi

run_or_die mkdir -p "$BACKUP_DIR"
need_kb=$(du -sk -- "$MX_HOME" | awk '{print $1}')
((DRY_RUN)) || require_free_kb "$BACKUP_DIR" "$need_kb" "MX home archive (uncompressed size, worst case)"

excludes=()
for e in $BACKUP_EXCLUDES; do
  excludes+=("--exclude=${e}")
done

partial="${archive}.partial"
cleanup_on_exit "$partial"
run_or_die tar -C "$MX_HOME" -czf "$partial" "${excludes[@]}" .
run_or_die mv -f -- "$partial" "$archive"
sha256_write "$archive"
mark_changed

if ((DRY_RUN)); then
  result auto "archive=${archive}"
fi

mx_version=unknown
[[ -f "${MX_HOME}/${MX_VERSION_FILE}" ]] && mx_version=$(head -n1 "${MX_HOME}/${MX_VERSION_FILE}")
patches=""
[[ -f "${MX_HOME}/.patches/applied.list" ]] && patches=$(cut -f1 "${MX_HOME}/.patches/applied.list" | paste -sd, -)
sum=$(sha256_of "$archive")
cat >"${archive%.tar.gz}.manifest" <<EOF
run_id=${RUN_ID}
type=mx_home
host=$(hostname -f 2>/dev/null || hostname)
mx_home=${MX_HOME}
mx_version=${mx_version}
patches=${patches}
file=$(basename "$archive")
sha256=${sum}
size_bytes=$(stat -c %s "$archive")
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
log_info "backup written ${archive} sha256=${sum}"
result changed "archive=${archive}" "sha256=${sum}"
