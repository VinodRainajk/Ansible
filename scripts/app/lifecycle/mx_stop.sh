#!/usr/bin/env bash
# Stop Murex services on the app VM: clean stop command, then TERM/KILL leftovers.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/mx.sh
source "${SCRIPTS_ROOT}/app/lib/mx.sh"

usage() {
  cat <<'EOF'
Usage: mx_stop.sh [--dry-run] [--run-id ID] [--mx-home DIR] [--mx-services "a b"] ...

Stops MX services. Already stopped -> RESULT status=ok.
Inputs (env or --flag): RUN_ID, MX_HOME, MX_USER, MX_SERVICES, MX_STOP_CMD,
MX_STOP_TIMEOUT, MX_KILL_GRACE, LOG_DIR.
EOF
}

SCRIPT_VARS=("${MX_VARS[@]}")
init_script mx_stop "$@"
mx_require_home_var
acquire_lock mx-app

mx_stop_services
result auto
