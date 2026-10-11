# shellcheck shell=bash
# Oracle DB-host helpers. Source after common.sh.
#
# Assumptions (see README "Oracle DB host"):
#   - scripts run as the oracle OS user with ORACLE_HOME/ORACLE_SID set
#   - DB_USER is a CyberArk-managed account with DATAPUMP_EXP_FULL_DATABASE /
#     DATAPUMP_IMP_FULL_DATABASE, SELECT on DBA_* views, and CREATE ANY DIRECTORY
#   - DB_PASSWORD is exported by Ansible (no_log) and is never put on argv;
#     it reaches sqlplus via stdin and expdp/impdp via a 0600 parfile
#   - passwords do not contain a double quote

: "${ORACLE_HOME:=/u01/app/oracle/product/19.0.0/dbhome_1}"
: "${DB_TNS:=}"
: "${DP_DIR_NAME:=MX_DP_DIR}"
: "${DP_DIR_PATH:=/u01/app/oracle/dpdump/murex}"

# shellcheck disable=SC2034  # consumed by the sourcing script
ORA_VARS=(ORACLE_HOME ORACLE_SID DB_USER DB_TNS DB_SCHEMA DP_DIR_NAME DP_DIR_PATH)

_PROTECTED_SCHEMAS=" SYS SYSTEM SYSMAN DBSNMP OUTLN XDB CTXSYS MDSYS ORDSYS WMSYS AUDSYS GSMADMIN_INTERNAL OJVMSYS LBACSYS DVSYS APPQOSSYS PUBLIC "

ora_init() {
  require_vars ORACLE_SID DB_USER DB_PASSWORD DB_SCHEMA
  [[ "$DB_PASSWORD" != *'"'* ]] || die 2 "DB_PASSWORD contains a double quote, which these scripts do not support"
  DB_SCHEMA=${DB_SCHEMA^^}
  require_match DB_SCHEMA '^[A-Z][A-Z0-9_$#]{0,127}$' "Oracle schema name"
  require_match DP_DIR_NAME '^[A-Za-z][A-Za-z0-9_]{0,127}$' "datapump directory name"
  [[ "$_PROTECTED_SCHEMAS" != *" ${DB_SCHEMA} "* ]] || die 2 "refusing to touch Oracle-maintained schema ${DB_SCHEMA}"
  [[ "$DB_SCHEMA" != "${DB_USER^^}" ]] || die 2 "DB_SCHEMA must not be the connecting account ${DB_USER}"
  export ORACLE_HOME ORACLE_SID
  export PATH="${ORACLE_HOME}/bin:${PATH}"
  require_cmd sqlplus
}

_ora_connect() { printf 'connect %s/"%s"%s\n' "$DB_USER" "$DB_PASSWORD" "${DB_TNS:+@${DB_TNS}}"; }

# ora_query <sql>; read-only, runs even under --dry-run. Prints trimmed rows.
ora_query() {
  local sql=$1 out rc=0
  out=$({
    echo "whenever sqlerror exit failure"
    echo "whenever oserror exit failure"
    _ora_connect
    echo "set heading off feedback off pagesize 0 linesize 32767 trimspool on verify off echo off"
    printf '%s\n' "$sql"
    echo "exit success"
  } | sqlplus -s -L /nolog 2>&1) || rc=$?
  if ((rc != 0)) || grep -qE '^(ORA|SP2|TNS)-[0-9]+' <<<"$out"; then
    _redact "$out" | log_stream ERROR "  sqlplus| "
    die 6 "sqlplus query failed rc=${rc}"
  fi
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^Connected\.$/d' <<<"$out"
}

# ora_exec <description> <sql>; mutating, skipped under --dry-run.
ora_exec() {
  local what=$1 sql=$2
  if ((DRY_RUN)); then
    log_info "DRY-RUN would execute SQL: ${what}"
    return 0
  fi
  log_info "sql: ${what}"
  ora_query "set serveroutput on size unlimited
${sql}" | log_stream INFO "  sql| "
}

ora_schema_exists() {
  [[ "$(ora_query "select count(*) from dba_users where username = '${DB_SCHEMA}';")" == 1 ]]
}

ora_object_count() {
  ora_query "select count(*) from dba_objects where owner = '${DB_SCHEMA}' and object_name not like 'BIN\$%';"
}

ora_ensure_directory() {
  if ((DRY_RUN)); then
    log_info "DRY-RUN would ensure ${DP_DIR_PATH} exists and directory ${DP_DIR_NAME} points to it"
    return 0
  fi
  mkdir -p "$DP_DIR_PATH"
  chmod 750 "$DP_DIR_PATH"
  local current
  current=$(ora_query "select directory_path from dba_directories where directory_name = '${DP_DIR_NAME^^}';")
  if [[ "$current" == "$DP_DIR_PATH" ]]; then
    log_info "datapump directory ${DP_DIR_NAME} already points to ${DP_DIR_PATH}"
    return 0
  fi
  ora_exec "create directory ${DP_DIR_NAME} -> ${DP_DIR_PATH}" \
    "create or replace directory ${DP_DIR_NAME} as '${DP_DIR_PATH}';"
}

# ora_parfile <path> <param lines...>; parfile carrying the credentials, mode 0600.
ora_parfile() {
  local pf=$1
  shift
  (
    umask 077
    {
      printf 'userid=%s/"%s"%s\n' "$DB_USER" "$DB_PASSWORD" "${DB_TNS:+@${DB_TNS}}"
      printf '%s\n' "$@"
    } >"$pf"
  )
}

# ora_datapump <expdp|impdp> <param lines...>; returns the tool's exit code
# (0 ok, 5 completed with errors, 1 fatal).
ora_datapump() {
  local tool=$1
  shift
  require_cmd "$tool"
  local params=("$@")
  if ((DRY_RUN)); then
    log_info "DRY-RUN would run ${tool} with: ${params[*]}"
    return 0
  fi
  local work pf rc=0
  work=$(mktemp -d)
  cleanup_on_exit "$work"
  pf="${work}/${tool}.par"
  ora_parfile "$pf" "${params[@]}"
  log_info "run: ${tool} parfile=<0600 temp> ${params[*]}"
  "$tool" parfile="$pf" 2>&1 | log_stream INFO "  ${tool}| " || rc=$?
  rm -f -- "$pf"
  return "$rc"
}
