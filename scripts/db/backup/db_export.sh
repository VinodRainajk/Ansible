#!/usr/bin/env bash
# expdp one schema on the Oracle DB host, then sha256 + manifest for JFrog upload.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/oracle.sh
source "${SCRIPTS_ROOT}/db/lib/oracle.sh"

usage() {
  cat <<'EOF'
Usage: db_export.sh [--dry-run] [--run-id ID] [--db-schema S] [--oracle-sid SID] [--db-user U] ...

Exports DB_SCHEMA with expdp into DP_DIR_PATH as <schema>_<RUN_ID>_NN.dmp,
plus .sha256 per file and <schema>_<RUN_ID>.manifest.
Same RUN_ID with a complete, verifying manifest -> RESULT status=ok.
DB_PASSWORD must be exported in the environment.
Inputs: RUN_ID, ORACLE_HOME, ORACLE_SID, DB_USER, DB_PASSWORD (env only),
DB_TNS (optional; empty = local bequeath via ORACLE_SID), DB_SCHEMA,
DP_DIR_NAME, DP_DIR_PATH, EXPDP_PARALLEL (default 1),
EXPDP_COMPRESSION (default METADATA_ONLY; ALL needs the Advanced Compression
option), EXPDP_CONSISTENT (default 1: FLASHBACK_TIME=SYSTIMESTAMP).
EOF
}

: "${EXPDP_PARALLEL:=1}"
: "${EXPDP_COMPRESSION:=METADATA_ONLY}"
: "${EXPDP_CONSISTENT:=1}"
SCRIPT_VARS=("${ORA_VARS[@]}" EXPDP_PARALLEL EXPDP_COMPRESSION EXPDP_CONSISTENT)
init_script db_export "$@"
ora_init
require_match EXPDP_PARALLEL '^[1-9][0-9]*$' "parallel degree"
require_match EXPDP_COMPRESSION '^(ALL|DATA_ONLY|METADATA_ONLY|NONE)$' "expdp COMPRESSION value"
acquire_lock "db-${DB_SCHEMA}"

base="${DB_SCHEMA,,}_${RUN_ID}"
manifest="${DP_DIR_PATH}/${base}.manifest"

if [[ -f "$manifest" ]]; then
  ok=1
  while IFS= read -r f; do
    sha256_verify "${DP_DIR_PATH}/${f}" || ok=0
  done < <(sed -n 's/^file=//p' "$manifest")
  if ((ok)); then
    log_info "export already complete for this run: ${manifest}"
    result ok "manifest=${manifest}"
  fi
  log_warn "manifest ${manifest} exists but files do not verify; exporting again"
fi

ora_schema_exists || die "schema ${DB_SCHEMA} does not exist in ${ORACLE_SID}"
ora_ensure_directory

shopt -s nullglob
stale=("${DP_DIR_PATH}/${base}"_*.dmp "${DP_DIR_PATH}/${base}"_*.dmp.sha256 "$manifest")
shopt -u nullglob
for f in "${stale[@]}"; do
  [[ -e "$f" ]] && run_or_die rm -f -- "$f"
done

params=(
  "schemas=${DB_SCHEMA}"
  "directory=${DP_DIR_NAME}"
  "dumpfile=${base}_%U.dmp"
  "logfile=${base}.exp.log"
  "parallel=${EXPDP_PARALLEL}"
  "compression=${EXPDP_COMPRESSION}"
  "reuse_dumpfiles=yes"
  "metrics=yes"
)
as_bool "$EXPDP_CONSISTENT" && params+=("flashback_time=systimestamp")

rc=0
ora_datapump expdp "${params[@]}" || rc=$?
((rc == 0)) || die "$rc" "expdp failed rc=${rc}; see ${DP_DIR_PATH}/${base}.exp.log"
mark_changed

if ((DRY_RUN)); then
  result auto "dir=${DP_DIR_PATH}" "base=${base}"
fi

grep -q "successfully completed" "${DP_DIR_PATH}/${base}.exp.log" ||
  die "expdp log does not report success: ${DP_DIR_PATH}/${base}.exp.log"

shopt -s nullglob
dumps=("${DP_DIR_PATH}/${base}"_*.dmp)
shopt -u nullglob
((${#dumps[@]} > 0)) || die "expdp produced no dump files matching ${base}_*.dmp"

{
  echo "run_id=${RUN_ID}"
  echo "type=oracle_schema"
  echo "oracle_sid=${ORACLE_SID}"
  echo "schema=${DB_SCHEMA}"
  echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for d in "${dumps[@]}"; do
    sha256_write "$d"
    echo "file=$(basename "$d")"
    echo "sha256.$(basename "$d")=$(sha256_of "$d")"
  done
  echo "log=${base}.exp.log"
} >"${manifest}.partial"
mv -f -- "${manifest}.partial" "$manifest"

log_info "export complete: ${#dumps[@]} file(s), manifest ${manifest}"
result changed "manifest=${manifest}" "files=${#dumps[@]}"
