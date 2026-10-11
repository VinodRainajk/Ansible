# shellcheck shell=bash
# Shared helpers for the Murex/Oracle support scripts. Source it; do not run it.
#
# Every script follows the same contract:
#   - inputs come from environment variables, or from --long-option flags that
#     map to the same names (--mx-home X sets MX_HOME=X)
#   - one log line per event: <ISO ts> <LEVEL> <run_id> <step> <message>
#     written to stdout and to $LOG_DIR/<step>.log
#   - exit 0 on success; non-zero after an ERROR line on failure
#   - the last INFO line on success is "RESULT status=ok|changed ..." so
#     Ansible can set changed_when from stdout
#   - --dry-run logs every mutating action instead of running it

if [[ -n "${_MX_COMMON_LOADED:-}" ]]; then
  return 0
fi
_MX_COMMON_LOADED=1

set -o errtrace

: "${DRY_RUN:=0}"
: "${FORCE:=0}"
CHANGED=0
_ERROR_LOGGED=0
_CLEANUP_PATHS=()
COMMON_VARS=(RUN_ID LOG_DIR LOCK_DIR)

# --- logging -----------------------------------------------------------------

_redact() {
  local msg=$1
  if [[ -n "${DB_PASSWORD:-}" ]]; then
    msg=${msg//"$DB_PASSWORD"/'****'}
  fi
  printf '%s' "$msg"
}

log() {
  local level=$1
  shift
  local msg line
  msg=$(_redact "$*")
  msg=${msg//$'\n'/ | }
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${level} ${RUN_ID:-no-run-id} ${STEP:-unknown} ${msg}"
  printf '%s\n' "$line"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() {
  _ERROR_LOGGED=1
  log ERROR "$@"
}

# Read lines from stdin and log each one (used for command output).
log_stream() {
  local level=${1:-INFO} prefix=${2:-}
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    log "$level" "${prefix}${line}"
  done
}

# die [rc] message...
die() {
  local rc=1
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    rc=$1
    shift
  fi
  log_error "$*"
  exit "$rc"
}

# result ok|changed [key=value ...]; logs the final status line and exits 0.
result() {
  local status=$1
  shift
  if [[ "$status" == auto ]]; then
    status=ok
    ((CHANGED)) && status=changed
  fi
  local extra=""
  ((DRY_RUN)) && extra=" dry_run=1"
  log_info "RESULT status=${status}${extra}${*:+ $*}"
  exit 0
}

mark_changed() { CHANGED=1; }

# --- traps -------------------------------------------------------------------

_on_err() {
  local rc=$1 line=$2 cmd=$3
  log_error "command failed rc=${rc} at ${BASH_SOURCE[1]:-?}:${line}: ${cmd}"
}

_on_exit() {
  local rc=$?
  local p
  for p in "${_CLEANUP_PATHS[@]}"; do
    [[ -n "$p" && -e "$p" ]] && rm -rf -- "$p"
  done
  if ((rc != 0)) && ((_ERROR_LOGGED == 0)); then
    log ERROR "exited with rc=${rc}"
  fi
  exit "$rc"
}

# Register a temp path to remove on exit (also on failure).
cleanup_on_exit() { _CLEANUP_PATHS+=("$@"); }

# --- argument handling -------------------------------------------------------

_in_list() {
  local needle=$1
  shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

_set_var() {
  local opt=$1 value=$2 name
  name=${opt#--}
  name=${name//-/_}
  name=${name^^}
  if [[ "$name" == DB_PASSWORD ]]; then
    die 2 "DB_PASSWORD must come from the environment (set by Ansible with no_log), never from an argument"
  fi
  if ! _in_list "$name" "${SCRIPT_VARS[@]}" "${COMMON_VARS[@]}"; then
    die 2 "unknown option ${opt} (see --help)"
  fi
  printf -v "$name" '%s' "$value"
  export "${name?}"
}

# Scripts define SCRIPT_VARS (allowed option names) and usage() before calling.
parse_args() {
  while (($#)); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      --force) FORCE=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      --*=*) _set_var "${1%%=*}" "${1#*=}" ;;
      --*)
        (($# >= 2)) || die 2 "missing value for $1"
        _set_var "$1" "$2"
        shift
        ;;
      *) die 2 "unexpected argument: $1 (see --help)" ;;
    esac
    shift
  done
}

require_vars() {
  local v missing=()
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  ((${#missing[@]} == 0)) || die 2 "missing required input(s): ${missing[*]}"
}

# require_match VAR regex description
require_match() {
  local v=$1 re=$2 what=$3
  [[ "${!v}" =~ $re ]] || die 2 "${v}='${!v}' is not a valid ${what}"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die 2 "required command not found: $c"
  done
}

# --- startup -----------------------------------------------------------------

# init_script <step> "$@"; sets up args, logging, traps and the lock.
init_script() {
  STEP=$1
  shift
  parse_args "$@"
  require_vars RUN_ID
  require_match RUN_ID '^[A-Za-z0-9._-]+$' "run id (letters, digits, . _ -)"

  # Ansible passes LOG_DIR=<script_log_dir>/<run_id>.
  : "${LOG_DIR:=/var/log/murex-ansible/script_logs/${RUN_ID}}"
  LOG_FALLBACK_USED=0
  if mkdir -p "$LOG_DIR" 2>/dev/null && [[ -w "$LOG_DIR" ]]; then
    LOG_FILE="${LOG_DIR}/${STEP}.log"
  else
    LOG_FALLBACK_USED=1
    if [[ -n "${LOG_FALLBACK_FILE:-}" ]]; then
      LOG_FILE=$LOG_FALLBACK_FILE
    else
      local fallback="${TMPDIR:-/tmp}/murex-ansible/script_logs/${RUN_ID}"
      mkdir -p "$fallback"
      LOG_FILE="${fallback}/${STEP}.log"
    fi
    printf '%s WARN %s %s log dir %s not writable, logging to %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ID" "$STEP" "$LOG_DIR" "$LOG_FILE" | tee -a "$LOG_FILE"
    LOG_DIR=$(dirname "$LOG_FILE")
  fi
  export LOG_DIR LOG_FILE LOG_FALLBACK_USED

  trap '_on_err $? $LINENO "$BASH_COMMAND"' ERR
  trap _on_exit EXIT

  log_info "start host=$(hostname -s 2>/dev/null || hostname) user=$(id -un) dry_run=${DRY_RUN} force=${FORCE} log=${LOG_FILE}"
}

# acquire_lock <name>; one run per lock name per host. The fd stays open until exit.
acquire_lock() {
  local name=$1
  : "${LOCK_DIR:=${TMPDIR:-/tmp}}"
  local f="${LOCK_DIR}/murex-support-${name}.lock"
  if ! command -v flock >/dev/null 2>&1; then
    log_warn "flock not installed; running without a lock on ${name}"
    return 0
  fi
  exec {_LOCK_FD}>"$f"
  flock -n "$_LOCK_FD" || die 3 "another support script holds lock ${f}; refusing to run concurrently"
}

# --- running commands --------------------------------------------------------

_quote_cmd() {
  local out="" a
  for a in "$@"; do
    out+="$(printf '%q' "$a") "
  done
  printf '%s' "${out% }"
}

# run cmd args...; mutating command. Logged, output streamed to the log,
# skipped under --dry-run. Returns the command's exit code.
run() {
  if ((DRY_RUN)); then
    log_info "DRY-RUN would run: $(_quote_cmd "$@")"
    return 0
  fi
  log_info "run: $(_quote_cmd "$@")"
  local rc=0
  # Daemons started here (MX services) must not inherit the lock fd, or the
  # lock would outlive this script.
  if [[ -n "${_LOCK_FD:-}" ]]; then
    "$@" {_LOCK_FD}>&- 2>&1 | log_stream INFO "  | " || rc=$?
  else
    "$@" 2>&1 | log_stream INFO "  | " || rc=$?
  fi
  return "$rc"
}

# run_or_die cmd args...; like run but fails the script on non-zero.
run_or_die() {
  local rc=0
  run "$@" || rc=$?
  ((rc == 0)) || die "$rc" "command failed rc=${rc}: $(_quote_cmd "$@")"
}

# --- files and checksums -----------------------------------------------------

sha256_of() { sha256sum -- "$1" | awk '{print $1}'; }

# Write <file>.sha256 in "hash  basename" format (sha256sum -c compatible).
sha256_write() {
  local f=$1
  if ((DRY_RUN)); then
    log_info "DRY-RUN would write ${f}.sha256"
    return 0
  fi
  (cd "$(dirname "$f")" && sha256sum -- "$(basename "$f")") >"${f}.sha256"
}

# sha256_verify <file> [expected]; uses <file>.sha256 when no hash is given.
# Returns 0 ok, 1 mismatch, 2 nothing to compare against.
sha256_verify() {
  local f=$1 expected=${2:-}
  if [[ -z "$expected" && -f "${f}.sha256" ]]; then
    expected=$(awk 'NR==1{print $1}' "${f}.sha256")
  fi
  [[ -n "$expected" ]] || return 2
  [[ "$(sha256_of "$f")" == "${expected,,}" ]]
}

# verify_artifact <file> <expected-or-empty> <require 0|1>
verify_artifact() {
  local f=$1 expected=$2 required=$3 rc=0
  [[ -f "$f" ]] || die 2 "artifact not found: $f"
  sha256_verify "$f" "$expected" || rc=$?
  case $rc in
    0) log_info "checksum ok: $(basename "$f")" ;;
    1) die 4 "checksum mismatch for $f" ;;
    *)
      ((required)) && die 4 "no checksum for $f (pass the expected sha256 or ship ${f}.sha256)"
      log_warn "no checksum available for $f; continuing because checksum is not required"
      ;;
  esac
}

# require_free_kb <dir> <kb> <what>
require_free_kb() {
  local dir=$1 need=$2 what=$3 avail
  avail=$(df -Pk -- "$dir" | awk 'NR==2{print $4}')
  ((avail >= need)) || die 5 "not enough space in ${dir} for ${what}: need ${need}KB, have ${avail}KB"
  log_info "space ok in ${dir}: need ${need}KB, have ${avail}KB"
}

# Refuse paths that would make rm -rf or tar dangerous.
# assert_safe_path <path> <allowed-prefix ...>
assert_safe_path() {
  local p=$1
  shift
  [[ "$p" == /* ]] || die 2 "path must be absolute: $p"
  [[ "$p" != *..* ]] || die 2 "path must not contain '..': $p"
  local stripped=${p%/}
  local depth
  depth=$(awk -F/ '{print NF-1}' <<<"$stripped")
  ((depth >= 2)) || die 2 "refusing shallow path: $p"
  local pre
  for pre in "$@"; do
    [[ "$stripped/" == "${pre%/}/"* && "$stripped" != "${pre%/}" ]] && return 0
  done
  die 2 "path ${p} is outside the allowed prefixes: $*"
}

as_bool() {
  case ${1,,} in
    1 | y | yes | true | on) return 0 ;;
    *) return 1 ;;
  esac
}
