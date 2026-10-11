#!/usr/bin/env bash
# Start Murex services on the app VM and wait until every service is up.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/mx.sh
source "${SCRIPTS_ROOT}/app/lib/mx.sh"

usage() {
  cat <<'EOF'
Usage: mx_start.sh [--dry-run] [--run-id ID] [--mx-home DIR] ...

Starts MX services and waits up to MX_START_TIMEOUT seconds for all of
MX_SERVICES to be running. Already running -> RESULT status=ok.
If MX_HEALTH_CMD is set it is run (as MX_USER, from MX_HOME) after start and
must exit 0.
Inputs (env or --flag): RUN_ID, MX_HOME, MX_USER, MX_SERVICES, MX_START_CMD,
MX_START_TIMEOUT, MX_HEALTH_CMD, LOG_DIR.
EOF
}

: "${MX_HEALTH_CMD:=}"
SCRIPT_VARS=("${MX_VARS[@]}" MX_HEALTH_CMD)
init_script mx_start "$@"
mx_require_home_var
acquire_lock mx-app

[[ -f "${MX_HOME}/${MX_HOME_MARKER}" ]] || die "MX_HOME ${MX_HOME} has no ${MX_HOME_MARKER}; nothing to start"

mx_probe
if [[ "$MX_STATE" == running ]]; then
  log_info "all MX services already running: ${MX_UP[*]}"
  result ok state=running
fi
[[ "$MX_STATE" == partial ]] && log_warn "MX is partially up (up: ${MX_UP[*]}; down: ${MX_DOWN[*]}); running start command anyway"

_split_cmd "$MX_START_CMD"
run_or_die run_as_mx timeout "$MX_START_TIMEOUT" "${_CMD[@]}"
mark_changed

if ((DRY_RUN)); then
  log_info "DRY-RUN would wait up to ${MX_START_TIMEOUT}s for: ${MX_SERVICES}"
  result auto
fi

mx_wait_for running "$MX_START_TIMEOUT" ||
  die "MX services not running after ${MX_START_TIMEOUT}s (down: ${MX_DOWN[*]})"
log_info "all MX services running: ${MX_UP[*]}"

if [[ -n "$MX_HEALTH_CMD" ]]; then
  _split_cmd "$MX_HEALTH_CMD"
  run_or_die run_as_mx "${_CMD[@]}"
  log_info "health check passed"
fi

result auto state=running
