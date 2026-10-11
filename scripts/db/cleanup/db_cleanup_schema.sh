#!/usr/bin/env bash
# Empty (default) or drop the Murex schema before a gold import.
# Ansible must only call this after the rollback expdp is confirmed in JFrog.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/oracle.sh
source "${SCRIPTS_ROOT}/db/lib/oracle.sh"

usage() {
  cat <<'EOF'
Usage: db_cleanup_schema.sh --confirm-schema S --backup-ref REF [--dry-run] [--run-id ID] [--db-schema S] ...

DB_CLEANUP_MODE:
  drop_objects (default) kill sessions, drop every object owned by DB_SCHEMA,
                         keep the user, its grants, quotas and password
  drop_user              kill sessions, DROP USER ... CASCADE; impdp must then
                         recreate the user (needs a privileged DB_USER)
Already empty / already absent -> RESULT status=ok.
Guards: CONFIRM_SCHEMA must equal DB_SCHEMA; BACKUP_REF (JFrog path of the
rollback dump) is required and logged; Oracle-maintained schemas are refused.
Known gaps: AQ queue tables and scheduler jobs are not handled specially; if
they block a drop, the remaining objects are listed and the script fails.
EOF
}

: "${DB_CLEANUP_MODE:=drop_objects}"
: "${CONFIRM_SCHEMA:=}"
: "${BACKUP_REF:=}"
SCRIPT_VARS=("${ORA_VARS[@]}" DB_CLEANUP_MODE CONFIRM_SCHEMA BACKUP_REF)
init_script db_cleanup_schema "$@"
ora_init
require_vars CONFIRM_SCHEMA BACKUP_REF
[[ "${CONFIRM_SCHEMA^^}" == "$DB_SCHEMA" ]] || die 2 "CONFIRM_SCHEMA (${CONFIRM_SCHEMA}) does not match DB_SCHEMA (${DB_SCHEMA})"
[[ "$DB_CLEANUP_MODE" == drop_objects || "$DB_CLEANUP_MODE" == drop_user ]] || die 2 "DB_CLEANUP_MODE must be drop_objects or drop_user"
acquire_lock "db-${DB_SCHEMA}"
log_info "cleanup of ${DB_SCHEMA} mode=${DB_CLEANUP_MODE} authorised by rollback backup ${BACKUP_REF}"

if ! ora_schema_exists; then
  log_info "schema ${DB_SCHEMA} does not exist; nothing to clean"
  result ok "schema=${DB_SCHEMA}" state=absent
fi

count=$(ora_object_count)
if [[ "$DB_CLEANUP_MODE" == drop_objects && "$count" == 0 ]]; then
  log_info "schema ${DB_SCHEMA} already has no objects"
  result ok "schema=${DB_SCHEMA}" objects=0
fi
log_info "schema ${DB_SCHEMA} has ${count} object(s)"

ora_exec "lock account and kill sessions of ${DB_SCHEMA}" "
alter user ${DB_SCHEMA} account lock;
begin
  for s in (select sid, serial#, inst_id from gv\$session where username = '${DB_SCHEMA}') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ',@' || s.inst_id || ''' immediate';
  end loop;
end;
/"

if [[ "$DB_CLEANUP_MODE" == drop_user ]]; then
  ora_exec "drop user ${DB_SCHEMA} cascade" "drop user ${DB_SCHEMA} cascade;"
  mark_changed
  ((DRY_RUN)) || ! ora_schema_exists || die "user ${DB_SCHEMA} still exists after drop"
  result auto "schema=${DB_SCHEMA}" state=dropped
fi

ora_exec "drop all objects owned by ${DB_SCHEMA} (3 passes)" "
declare
  l_owner constant varchar2(128) := '${DB_SCHEMA}';
begin
  for pass in 1 .. 3 loop
    for o in (select object_name, object_type
                from dba_objects
               where owner = l_owner
                 and object_name not like 'BIN\$%'
                 and object_type in ('MATERIALIZED VIEW','TABLE','VIEW','SEQUENCE','SYNONYM',
                                     'PACKAGE','PROCEDURE','FUNCTION','TRIGGER','TYPE',
                                     'JAVA SOURCE','JAVA CLASS','JAVA RESOURCE','DATABASE LINK')
               order by decode(object_type,'MATERIALIZED VIEW',1,'TABLE',2,'VIEW',3,'TYPE',9,5)) loop
      begin
        case o.object_type
          when 'TABLE' then
            execute immediate 'drop table \"' || l_owner || '\".\"' || o.object_name || '\" cascade constraints purge';
          when 'TYPE' then
            execute immediate 'drop type \"' || l_owner || '\".\"' || o.object_name || '\" force';
          when 'DATABASE LINK' then
            null;
          else
            execute immediate 'drop ' || o.object_type || ' \"' || l_owner || '\".\"' || o.object_name || '\"';
        end case;
      exception
        when others then null;
      end;
    end loop;
  end loop;
end;
/"
mark_changed

if ! ((DRY_RUN)); then
  left=$(ora_object_count)
  if [[ "$left" != 0 ]]; then
    ora_query "select object_type || ' ' || object_name from dba_objects where owner = '${DB_SCHEMA}' and object_name not like 'BIN\$%' and rownum <= 20;" |
      log_stream ERROR "  remaining| "
    die "${left} object(s) still owned by ${DB_SCHEMA} after cleanup (database links and queue tables need manual handling)"
  fi
fi
ora_exec "unlock account ${DB_SCHEMA}" "alter user ${DB_SCHEMA} account unlock;"
result auto "schema=${DB_SCHEMA}" objects=0
