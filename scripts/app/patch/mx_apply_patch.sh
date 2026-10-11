#!/usr/bin/env bash
# Apply one Murex patch archive (staged by Ansible from JFrog) to MX_HOME.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/mx.sh
source "${SCRIPTS_ROOT}/app/lib/mx.sh"

usage() {
  cat <<'EOF'
Usage: mx_apply_patch.sh --patch-file FILE --patch-id ID [--patch-sha256 HEX] [--dry-run] [--run-id ID] [--mx-home DIR]

Assumed patch archive layout (.tar.gz, .tgz or .zip), all parts optional but
at least one of files/ or patch.sh must exist:
  files/      copied over MX_HOME (same relative paths)
  sql/*.sql   run in name order with sqlplus from the app VM (needs DB_TNS,
              DB_USER, DB_PASSWORD); each one is recorded so a re-run skips it
  patch.sh    vendor/support hook, run as MX_USER from MX_HOME with
              MX_HOME, PATCH_ID, RUN_ID exported
MX services must be stopped (run mx_stop.sh first; mx_start.sh after).
Files that get overwritten are saved first to MX_HOME/.patches/<ID>/backup.tar.gz
(once; a re-run never overwrites that backup).
PATCH_ID already in MX_HOME/.patches/applied.list -> RESULT status=ok.
EOF
}

: "${PATCH_FILE:=}"
: "${PATCH_ID:=}"
: "${PATCH_SHA256:=}"
: "${REQUIRE_CHECKSUM:=1}"
: "${PATCH_WORK_DIR:=}"
: "${DB_TNS:=}"
: "${DB_USER:=}"
SCRIPT_VARS=("${MX_VARS[@]}" PATCH_FILE PATCH_ID PATCH_SHA256 REQUIRE_CHECKSUM PATCH_WORK_DIR DB_TNS DB_USER)
init_script mx_apply_patch "$@"
mx_require_home_var
require_vars PATCH_FILE PATCH_ID
require_match PATCH_ID '^[A-Za-z0-9._-]+$' "patch id"
acquire_lock mx-app

[[ -f "${MX_HOME}/${MX_HOME_MARKER}" ]] || die "no MX install at ${MX_HOME} (missing ${MX_HOME_MARKER})"
pdir="${MX_HOME}/.patches/${PATCH_ID}"
applied="${MX_HOME}/.patches/applied.list"

if [[ -f "$applied" ]] && awk -F'\t' -v id="$PATCH_ID" '$1 == id {found=1} END {exit !found}' "$applied"; then
  log_info "patch ${PATCH_ID} already applied"
  result ok "patch_id=${PATCH_ID}"
fi

verify_artifact "$PATCH_FILE" "$PATCH_SHA256" "$(as_bool "$REQUIRE_CHECKSUM" && echo 1 || echo 0)"
sum=$(sha256_of "$PATCH_FILE")
mx_require_stopped

work=${PATCH_WORK_DIR:-$(dirname "$MX_HOME")/patch-work}/${PATCH_ID}-${RUN_ID}
[[ "$work/" != "$MX_HOME/"* ]] || die 2 "PATCH_WORK_DIR must be outside MX_HOME"
rm -rf -- "$work"
mkdir -p "$work"
cleanup_on_exit "$work"
case $PATCH_FILE in
  *.tar.gz | *.tgz) tar -C "$work" -xzf "$PATCH_FILE" ;;
  *.zip)
    require_cmd unzip
    unzip -q "$PATCH_FILE" -d "$work"
    ;;
  *) die 2 "unsupported patch archive type: $PATCH_FILE" ;;
esac

root=$work
if [[ ! -d "$root/files" && ! -f "$root/patch.sh" ]]; then
  mapfile -t tops < <(find "$work" -mindepth 1 -maxdepth 1)
  if ((${#tops[@]} == 1)) && [[ -d "${tops[0]}" ]]; then
    root=${tops[0]}
  fi
fi
[[ -d "$root/files" || -f "$root/patch.sh" ]] || die "patch ${PATCH_ID} has neither files/ nor patch.sh at its root"
log_info "patch ${PATCH_ID} sha256=${sum} files=$([[ -d $root/files ]] && echo yes || echo no) sql=$([[ -d $root/sql ]] && echo yes || echo no) hook=$([[ -f $root/patch.sh ]] && echo yes || echo no)"

run_or_die mkdir -p "$pdir"

if [[ -d "$root/files" ]]; then
  mapfile -t rel < <(cd "$root/files" && find . -type f -o -type l | sed 's|^\./||' | sort)
  if [[ -f "$pdir/backup.tar.gz" ]]; then
    log_info "pre-patch backup already taken: $pdir/backup.tar.gz"
  else
    existing=()
    added=()
    for r in "${rel[@]}"; do
      if [[ -e "${MX_HOME}/${r}" ]]; then existing+=("$r"); else added+=("$r"); fi
    done
    if ((DRY_RUN)); then
      log_info "DRY-RUN would back up ${#existing[@]} file(s) to $pdir/backup.tar.gz and record ${#added[@]} new file(s)"
    else
      printf '%s\n' "${added[@]}" >"$pdir/added.list"
      tar -C "$MX_HOME" -czf "$pdir/backup.tar.gz.partial" -T <(printf '%s\n' "${existing[@]}")
      mv -f -- "$pdir/backup.tar.gz.partial" "$pdir/backup.tar.gz"
      log_info "backed up ${#existing[@]} file(s); ${#added[@]} new file(s) listed in $pdir/added.list"
    fi
  fi
  run_or_die cp -a -- "$root/files/." "$MX_HOME/"
  mx_chown "$MX_HOME"
  mark_changed
fi

if [[ -d "$root/sql" ]]; then
  mapfile -t sqls < <(find "$root/sql" -maxdepth 1 -type f -name '*.sql' | sort)
  if ((${#sqls[@]})); then
    require_vars DB_TNS DB_USER DB_PASSWORD
    require_cmd sqlplus
    [[ "$DB_PASSWORD" != *'"'* ]] || die 2 "DB_PASSWORD contains a double quote, which these scripts do not support"
    touch "$pdir/sql.done" 2>/dev/null || ((DRY_RUN))
    for s in "${sqls[@]}"; do
      n=$(basename "$s")
      if [[ -f "$pdir/sql.done" ]] && grep -qx "$n" "$pdir/sql.done"; then
        log_info "sql ${n} already run for ${PATCH_ID}"
        continue
      fi
      if ((DRY_RUN)); then
        log_info "DRY-RUN would run sql ${n} against ${DB_TNS} as ${DB_USER}"
        continue
      fi
      log_info "sql: running ${n} against ${DB_TNS} as ${DB_USER}"
      rc=0
      {
        echo "whenever sqlerror exit failure"
        echo "whenever oserror exit failure"
        printf 'connect %s/"%s"@%s\n' "$DB_USER" "$DB_PASSWORD" "$DB_TNS"
        echo "set echo on feedback on"
        printf '@"%s"\n' "$s"
        echo "exit success"
      } | (cd "$(dirname "$s")" && sqlplus -s -L /nolog) 2>&1 | log_stream INFO "  sql| " || rc=$?
      ((rc == 0)) || die "$rc" "sql ${n} failed rc=${rc}; fix and re-run (completed scripts are skipped)"
      echo "$n" >>"$pdir/sql.done"
      mark_changed
    done
  fi
fi

if [[ -f "$root/patch.sh" ]]; then
  chmod +x "$root/patch.sh"
  run_or_die run_as_mx env MX_HOME="$MX_HOME" PATCH_ID="$PATCH_ID" RUN_ID="$RUN_ID" "$root/patch.sh"
  mark_changed
fi

if ((DRY_RUN)); then
  log_info "DRY-RUN would record ${PATCH_ID} in ${applied}"
else
  printf '%s\t%s\t%s\t%s\n' "$PATCH_ID" "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sum" >>"$applied"
fi
result auto "patch_id=${PATCH_ID}" "sha256=${sum}"
