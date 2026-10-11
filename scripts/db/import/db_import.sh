#!/usr/bin/env bash
# impdp a gold (or rollback) dump into DB_SCHEMA on the Oracle DB host.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/oracle.sh
source "${SCRIPTS_ROOT}/db/lib/oracle.sh"

usage() {
  cat <<'EOF'
Usage: db_import.sh --dump-files "a_01.dmp,a_02.dmp" [--source-schema S] [--dry-run] [--run-id ID] ...

DUMP_FILES: comma-separated dump paths staged by Ansible (from JFrog). Each is
checksum-verified (FILE.sha256 or DUMP_SHA256 for a single file) and copied
into DP_DIR_PATH if it is elsewhere.
SOURCE_SCHEMA: schema name inside the dump (default DB_SCHEMA); remapped when different.
TABLE_EXISTS_ACTION: SKIP | APPEND | TRUNCATE | REPLACE (default REPLACE).
REMAP_TABLESPACE: optional, comma-separated "SRC:DST" pairs.
IMPDP_STRICT=1 treats impdp rc=5 (completed with errors) as failure; default
logs it as WARN, because gold imports usually raise harmless ORA-31684 lines.
After import the schema is recompiled and invalid objects are counted
(more than MAX_INVALID, default 0, is a WARN).
Same RUN_ID and same dump checksums already imported -> RESULT status=ok.
EOF
}

: "${DUMP_FILES:=}"
: "${DUMP_SHA256:=}"
: "${SOURCE_SCHEMA:=}"
: "${TABLE_EXISTS_ACTION:=REPLACE}"
: "${REMAP_TABLESPACE:=}"
: "${IMPDP_PARALLEL:=1}"
: "${IMPDP_STRICT:=0}"
: "${MAX_INVALID:=0}"
: "${REQUIRE_CHECKSUM:=1}"
SCRIPT_VARS=("${ORA_VARS[@]}" DUMP_FILES DUMP_SHA256 SOURCE_SCHEMA TABLE_EXISTS_ACTION
  REMAP_TABLESPACE IMPDP_PARALLEL IMPDP_STRICT MAX_INVALID REQUIRE_CHECKSUM)
init_script db_import "$@"
ora_init
require_vars DUMP_FILES
TABLE_EXISTS_ACTION=${TABLE_EXISTS_ACTION^^}
require_match TABLE_EXISTS_ACTION '^(SKIP|APPEND|TRUNCATE|REPLACE)$' "TABLE_EXISTS_ACTION"
require_match IMPDP_PARALLEL '^[1-9][0-9]*$' "parallel degree"
SOURCE_SCHEMA=${SOURCE_SCHEMA:-$DB_SCHEMA}
SOURCE_SCHEMA=${SOURCE_SCHEMA^^}
require_match SOURCE_SCHEMA '^[A-Z][A-Z0-9_$#]{0,127}$' "Oracle schema name"
acquire_lock "db-${DB_SCHEMA}"

IFS=',' read -ra dumps <<<"$DUMP_FILES"
((${#dumps[@]} == 1)) || [[ -z "$DUMP_SHA256" ]] || die 2 "DUMP_SHA256 only applies to a single dump file"
require_checksum=0
as_bool "$REQUIRE_CHECKSUM" && require_checksum=1

sums=()
for d in "${dumps[@]}"; do
  verify_artifact "$d" "$DUMP_SHA256" "$require_checksum"
  sums+=("$(basename "$d")=$(sha256_of "$d")")
done
fingerprint=$(printf '%s\n' "${sums[@]}" | sort | sha256sum | awk '{print $1}')
done_marker="${DP_DIR_PATH}/.import_${DB_SCHEMA}_${RUN_ID}.done"

if [[ -f "$done_marker" ]] && grep -qx "fingerprint=${fingerprint}" "$done_marker"; then
  log_info "these dump files were already imported into ${DB_SCHEMA} for this run"
  result ok "schema=${DB_SCHEMA}"
fi

ora_ensure_directory

names=()
for d in "${dumps[@]}"; do
  name=$(basename "$d")
  names+=("$name")
  if [[ "$(dirname "$(readlink -f "$d")")" != "$(readlink -f "$DP_DIR_PATH" 2>/dev/null || echo "$DP_DIR_PATH")" ]]; then
    run_or_die cp -f -- "$d" "${DP_DIR_PATH}/${name}"
  fi
done

if ora_schema_exists; then
  existing=$(ora_object_count)
  if [[ "$existing" != 0 ]]; then
    log_warn "schema ${DB_SCHEMA} already has ${existing} object(s); TABLE_EXISTS_ACTION=${TABLE_EXISTS_ACTION}"
  fi
else
  log_info "schema ${DB_SCHEMA} does not exist; impdp will create it from the dump"
fi

base="${DB_SCHEMA,,}_${RUN_ID}"
params=(
  "directory=${DP_DIR_NAME}"
  "dumpfile=$(IFS=,; echo "${names[*]}")"
  "logfile=${base}.imp.log"
  "schemas=${SOURCE_SCHEMA}"
  "table_exists_action=${TABLE_EXISTS_ACTION}"
  "parallel=${IMPDP_PARALLEL}"
  "metrics=yes"
)
[[ "$SOURCE_SCHEMA" != "$DB_SCHEMA" ]] && params+=("remap_schema=${SOURCE_SCHEMA}:${DB_SCHEMA}")
[[ -n "$REMAP_TABLESPACE" ]] && params+=("remap_tablespace=${REMAP_TABLESPACE}")

rc=0
ora_datapump impdp "${params[@]}" || rc=$?
case $rc in
  0) ;;
  5)
    errs=$(grep -c '^ORA-' "${DP_DIR_PATH}/${base}.imp.log" 2>/dev/null || true)
    if as_bool "$IMPDP_STRICT"; then
      die 5 "impdp completed with errors (${errs:-?} ORA- lines) and IMPDP_STRICT=1; see ${DP_DIR_PATH}/${base}.imp.log"
    fi
    log_warn "impdp completed with ${errs:-?} ORA- line(s); review ${DP_DIR_PATH}/${base}.imp.log"
    ;;
  *) die "$rc" "impdp failed rc=${rc}; see ${DP_DIR_PATH}/${base}.imp.log" ;;
esac
mark_changed

ora_exec "recompile invalid objects in ${DB_SCHEMA}" \
  "begin dbms_utility.compile_schema(schema => '${DB_SCHEMA}', compile_all => false); end;
/"

if ((DRY_RUN)); then
  result auto "schema=${DB_SCHEMA}"
fi

invalid=$(ora_query "select count(*) from dba_objects where owner = '${DB_SCHEMA}' and status = 'INVALID';")
objects=$(ora_object_count)
if ((invalid > MAX_INVALID)); then
  log_warn "${invalid} invalid object(s) in ${DB_SCHEMA} after import (MAX_INVALID=${MAX_INVALID})"
fi
printf 'run_id=%s\nschema=%s\nfingerprint=%s\nimported_utc=%s\n' \
  "$RUN_ID" "$DB_SCHEMA" "$fingerprint" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$done_marker"
result changed "schema=${DB_SCHEMA}" "objects=${objects}" "invalid=${invalid}"
