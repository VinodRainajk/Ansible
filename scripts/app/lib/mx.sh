# shellcheck shell=bash
# Murex app-VM helpers. Source after common.sh.
#
# Assumptions (see README "Murex app VM"):
#   - MX services are started/stopped by shell commands run from MX_HOME as
#     MX_USER (default ./launchall.sh and ./stopall.sh), not by systemd
#   - each service is a process owned by MX_USER whose command line contains
#     both MX_HOME and the service name from MX_SERVICES

: "${MX_USER:=murex}"
: "${MX_GROUP:=murex}"
: "${MX_SERVICES:=fileserver xmlserver launcher}"
: "${MX_START_CMD:=./launchall.sh}"
: "${MX_STOP_CMD:=./stopall.sh}"
: "${MX_START_TIMEOUT:=600}"
: "${MX_STOP_TIMEOUT:=300}"
: "${MX_KILL_GRACE:=30}"
: "${MX_HOME_MARKER:=launchall.sh}"
: "${MX_ALLOWED_PREFIXES:=/opt/murex}"

# shellcheck disable=SC2034  # consumed by the sourcing script
MX_VARS=(MX_HOME MX_USER MX_GROUP MX_SERVICES MX_START_CMD MX_STOP_CMD
  MX_START_TIMEOUT MX_STOP_TIMEOUT MX_KILL_GRACE MX_HOME_MARKER MX_ALLOWED_PREFIXES)

mx_require_home_var() {
  require_vars MX_HOME
  MX_HOME=${MX_HOME%/}
  # shellcheck disable=SC2086
  assert_safe_path "$MX_HOME" $MX_ALLOWED_PREFIXES
  id "$MX_USER" >/dev/null 2>&1 || die 2 "MX_USER '${MX_USER}' does not exist on this host"
}

# run_as_mx cmd args...; runs from MX_HOME (or / if it is gone) as MX_USER.
run_as_mx() {
  if [[ "$(id -un)" == "$MX_USER" ]]; then
    (cd "$MX_HOME" 2>/dev/null || cd /; "$@")
  else
    sudo -n -u "$MX_USER" -- bash -c 'cd "$1" 2>/dev/null || cd /; shift; exec "$@"' _ "$MX_HOME" "$@"
  fi
}

mx_service_pids() {
  local svc=$1
  pgrep -u "$MX_USER" -f -- "${MX_HOME}.*${svc}|${svc}.*${MX_HOME}" 2>/dev/null || true
}

# Every MX_USER process that mentions MX_HOME (catches strays not in MX_SERVICES).
mx_all_pids() {
  pgrep -u "$MX_USER" -f -- "${MX_HOME}" 2>/dev/null | grep -vx "$$" || true
}

# Sets MX_STATE (running|stopped|partial), MX_UP and MX_DOWN (service lists).
mx_probe() {
  local svc
  MX_UP=()
  MX_DOWN=()
  for svc in $MX_SERVICES; do
    if [[ -n "$(mx_service_pids "$svc")" ]]; then
      MX_UP+=("$svc")
    else
      MX_DOWN+=("$svc")
    fi
  done
  if ((${#MX_DOWN[@]} == 0)); then
    MX_STATE=running
  elif ((${#MX_UP[@]} == 0)); then
    MX_STATE=stopped
  else
    MX_STATE=partial
  fi
}

# mx_wait_for <running|stopped> <timeout-seconds>
mx_wait_for() {
  local want=$1 timeout=$2 waited=0
  while :; do
    mx_probe
    [[ "$MX_STATE" == "$want" ]] && return 0
    ((waited >= timeout)) && return 1
    sleep 5
    waited=$((waited + 5))
  done
}

_split_cmd() {
  # shellcheck disable=SC2206
  _CMD=($1)
}

# Stop MX cleanly, then TERM, then KILL leftovers. Marks changed if anything ran.
mx_stop_services() {
  mx_probe
  local strays
  strays=$(mx_all_pids)
  if [[ "$MX_STATE" == stopped && -z "$strays" ]]; then
    log_info "MX services already stopped"
    return 0
  fi
  log_info "MX state=${MX_STATE} up=[${MX_UP[*]}]; stopping"
  mark_changed

  _split_cmd "$MX_STOP_CMD"
  local stop_bin=${_CMD[0]}
  [[ "$stop_bin" == /* ]] || stop_bin="${MX_HOME}/${stop_bin#./}"
  if [[ -x "$stop_bin" ]]; then
    local rc=0
    run run_as_mx timeout "$MX_STOP_TIMEOUT" "${_CMD[@]}" || rc=$?
    ((rc == 0)) || log_warn "stop command returned rc=${rc}; falling back to signals"
  else
    log_warn "stop command ${MX_STOP_CMD} not found in ${MX_HOME}; using signals only"
  fi

  if ((DRY_RUN)); then
    log_info "DRY-RUN would wait up to ${MX_STOP_TIMEOUT}s for services to stop, then TERM/KILL leftovers"
    return 0
  fi

  mx_wait_for stopped "$MX_STOP_TIMEOUT" || log_warn "services still up after ${MX_STOP_TIMEOUT}s: ${MX_UP[*]}"

  local pids
  pids=$(mx_all_pids)
  if [[ -n "$pids" ]]; then
    log_warn "sending TERM to leftover MX processes: $(tr '\n' ' ' <<<"$pids")"
    # shellcheck disable=SC2086
    run run_as_mx kill -TERM $pids || true
    sleep "$MX_KILL_GRACE"
    pids=$(mx_all_pids)
    if [[ -n "$pids" ]]; then
      log_warn "sending KILL to leftover MX processes: $(tr '\n' ' ' <<<"$pids")"
      # shellcheck disable=SC2086
      run run_as_mx kill -KILL $pids || true
      sleep 2
    fi
  fi

  mx_probe
  pids=$(mx_all_pids)
  [[ "$MX_STATE" == stopped && -z "$pids" ]] ||
    die "MX processes still running after stop: $(tr '\n' ' ' <<<"$pids")"
  log_info "MX services stopped"
}

mx_require_stopped() {
  mx_probe
  [[ "$MX_STATE" == stopped ]] || die "MX services are ${MX_STATE} (up: ${MX_UP[*]}); run mx_stop.sh first"
}

# chown to MX_USER:MX_GROUP when running as root; no-op otherwise.
mx_chown() {
  if ((EUID == 0)); then
    run_or_die chown -R "${MX_USER}:${MX_GROUP}" "$@"
  fi
}
