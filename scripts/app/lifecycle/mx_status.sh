#!/usr/bin/env bash
# Report Murex service state on the app VM. Read-only; no lock.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/mx.sh
source "${SCRIPTS_ROOT}/app/lib/mx.sh"

usage() {
  cat <<'EOF'
Usage: mx_status.sh [--run-id ID] [--mx-home DIR] [--expect running|stopped]

Prints one line per service and a final "RESULT status=ok state=<running|stopped|partial>".
Without --expect it always exits 0 once the check ran.
With --expect, a different state is a failure (ERROR line, exit 1).
Also reports MX_HOME presence and the applied patch list.
EOF
}

: "${EXPECT:=}"
SCRIPT_VARS=("${MX_VARS[@]}" EXPECT)
init_script mx_status "$@"
mx_require_home_var
[[ -z "$EXPECT" || "$EXPECT" == running || "$EXPECT" == stopped ]] || die 2 "EXPECT must be running or stopped"

if [[ -f "${MX_HOME}/${MX_HOME_MARKER}" ]]; then
  log_info "mx_home=${MX_HOME} present"
else
  log_info "mx_home=${MX_HOME} absent or not an MX install (no ${MX_HOME_MARKER})"
fi

patches=none
if [[ -f "${MX_HOME}/.patches/applied.list" ]]; then
  patches=$(cut -f1 "${MX_HOME}/.patches/applied.list" | paste -sd, -)
fi

mx_probe
for svc in $MX_SERVICES; do
  pids=$(mx_service_pids "$svc" | paste -sd, -)
  log_info "service=${svc} state=$([[ -n "$pids" ]] && echo running || echo stopped) pids=${pids:-none}"
done

if [[ -n "$EXPECT" && "$MX_STATE" != "$EXPECT" ]]; then
  die 1 "expected MX to be ${EXPECT} but it is ${MX_STATE} (up: ${MX_UP[*]}; down: ${MX_DOWN[*]})"
fi
result ok "state=${MX_STATE}" "up=${#MX_UP[@]}/$(wc -w <<<"$MX_SERVICES")" "patches=${patches:-none}"
