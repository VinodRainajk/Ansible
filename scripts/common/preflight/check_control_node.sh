#!/usr/bin/env bash
# Section 0, step A: can this control node run the playbooks at all?
# Plain shell on purpose: a broken Ansible install cannot report on itself.
# Runs every check, logs each one, and exits 1 if any failed.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/common/preflight/check_control_node.sh --env <dev|qa|uat|preprod> [options]

Checks, in order (all run; the script fails at the end if any failed):
  ansible_installed  ansible-playbook, ansible-inventory, ansible-galaxy, ansible-vault on PATH
  ansible_version    ansible-core between ANSIBLE_CORE_MIN and ANSIBLE_CORE_MAX (major.minor)
  python_version     Python used by Ansible >= PYTHON_MIN
  collections        cyberark.pas, community.general, ansible.posix installed
  repo_layout        ansible.cfg, playbooks/, roles/, scripts/, collections/requirements.yml
  inventory_parse    inventories/<env> parses; murex_app and oracle_db each have a host
  inventory_hosts    hosts.yml has no CHANGE-ME placeholder hosts left
  credentials        use_cyberark=false: credentials.yml exists, is not a placeholder,
                     and (if vault-encrypted) the vault password file opens it
                     use_cyberark=true:  CCP URL and AppID are filled in
  inventory_vars     every group_vars file parses (ansible-inventory --list)
  run_logs           <log_base_dir>/run_logs can be created, written and cleaned
  disk_logs          free space for logs   >= preflight_min_free_mb_logs
  disk_stage         free space in control_stage_dir >= preflight_min_free_mb_stage
  sshpass            present (WARN only; needed for SSH password logins)

Options (or the matching environment variables):
  --env NAME                    environment folder under inventories/ (required)
  --inventory-dir DIR           use another inventory folder (default inventories/<env>)
  --vault-password-file FILE    lets the script open an encrypted credentials.yml
                                (also read from ANSIBLE_VAULT_PASSWORD_FILE)
  --log-base-dir DIR            override log_base_dir from group_vars/all/main.yml
  --ansible-core-min X.Y        default 2.16
  --ansible-core-max X.Y        default 2.21
  --python-min X.Y              default 3.10

Log: <log_base_dir>/run_logs/<run_id>/check_control_node.log, or
/tmp/murex-ansible-preflight-<run_id>.log if run_logs cannot be created.
EOF
}

args=()
while (($#)); do
  case $1 in
    --env) args+=(--murex-env "${2:-}"); shift ;;
    --env=*) args+=("--murex-env=${1#--env=}") ;;
    *) args+=("$1") ;;
  esac
  shift
done

: "${MUREX_ENV:=}"
: "${INVENTORY_DIR:=}"
: "${VAULT_PASSWORD_FILE:=${ANSIBLE_VAULT_PASSWORD_FILE:-}}"
: "${LOG_BASE_DIR:=}"
: "${ANSIBLE_CORE_MIN:=2.16}"
: "${ANSIBLE_CORE_MAX:=2.21}"
: "${PYTHON_MIN:=3.10}"
SCRIPT_VARS=(MUREX_ENV INVENTORY_DIR VAULT_PASSWORD_FILE LOG_BASE_DIR ANSIBLE_CORE_MIN ANSIBLE_CORE_MAX PYTHON_MIN)
parse_args "${args[@]}"
[[ -n "$MUREX_ENV" ]] || { usage; die 2 "--env is required"; }
require_match MUREX_ENV '^[a-z0-9_-]+$' "environment name"

REPO_ROOT=$(cd "${SCRIPTS_ROOT}/.." && pwd)
[[ -z "$INVENTORY_DIR" ]] || INVENTORY_DIR=$(cd "$INVENTORY_DIR" && pwd)
cd "$REPO_ROOT"
export ANSIBLE_CONFIG="${REPO_ROOT}/ansible.cfg"
INV="${INVENTORY_DIR:-inventories/${MUREX_ENV}}"
MAIN_VARS="${INV}/group_vars/all/main.yml"
CREDS="${INV}/group_vars/all/credentials.yml"

# Flat "key: value" lookup in main.yml; these keys are kept literal on purpose.
yaml_value() {
  [[ -f "$MAIN_VARS" ]] || return 0
  sed -n "s/^$1:[[:space:]]*//p" "$MAIN_VARS" | head -n1 | sed -e 's/[[:space:]]#.*$//' -e 's/^["'\'']//' -e 's/["'\'']$//'
}

: "${LOG_BASE_DIR:=$(yaml_value log_base_dir)}"
: "${LOG_BASE_DIR:=/var/log/murex-ansible/${MUREX_ENV}}"
MIN_FREE_MB_LOGS=$(yaml_value preflight_min_free_mb_logs)
MIN_FREE_MB_STAGE=$(yaml_value preflight_min_free_mb_stage)
CONTROL_STAGE_DIR=$(yaml_value control_stage_dir)
USE_CYBERARK=$(yaml_value use_cyberark)
: "${MIN_FREE_MB_LOGS:=500}" "${MIN_FREE_MB_STAGE:=2048}" "${USE_CYBERARK:=false}"
: "${CONTROL_STAGE_DIR:=/var/tmp/murex-ansible/${MUREX_ENV}/stage}"

RUN_ID="${MUREX_ENV}-check-control-node-$(date -u +%Y%m%d-%H%M%S)"
RUN_LOGS="${LOG_BASE_DIR}/run_logs"
export RUN_ID
export LOG_DIR="${RUN_LOGS}/${RUN_ID}"
export LOG_FALLBACK_FILE="/tmp/murex-ansible-preflight-${RUN_ID}.log"
init_script preflight

CTRL=$(hostname -s 2>/dev/null || hostname)
FAILED=()
pass() { log_info "host=${CTRL} check=$1 ok${2:+ detail=$2}"; }
warn() { log_warn "host=${CTRL} check=$1 detail=$2"; }
fail() {
  log_error "host=${CTRL} check=$1 detail=$2"
  FAILED+=("$1")
}
# version_ge A B: A >= B for dotted versions
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }
major_minor() { awk -F. '{print $1"."$2}' <<<"$1"; }

log_info "control node check env=${MUREX_ENV} repo=${REPO_ROOT} inventory=${INV} log_base_dir=${LOG_BASE_DIR}"

# ansible_installed / ansible_version / python_version
missing=()
for c in ansible ansible-playbook ansible-inventory ansible-galaxy ansible-vault; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if ((${#missing[@]})); then
  fail ansible_installed "not on PATH: ${missing[*]} (install with: python3 -m pip install --user 'ansible-core>=${ANSIBLE_CORE_MIN},<$(awk -F. '{print $1"."$2+1}' <<<"$ANSIBLE_CORE_MAX")')"
  ANSIBLE_OK=0
else
  pass ansible_installed "$(command -v ansible-playbook)"
  ANSIBLE_OK=1
  ver_out=$(ansible --version 2>&1 || true)
  core=$(sed -n 's/^ansible \[core \([0-9][0-9.]*\)\].*/\1/p' <<<"$ver_out" | head -n1)
  py=$(sed -n 's/^ *python version = \([0-9][0-9.]*\).*/\1/p' <<<"$ver_out" | head -n1)
  if [[ -z "$core" ]]; then
    fail ansible_version "could not read the ansible-core version from 'ansible --version'"
  elif version_ge "$(major_minor "$core")" "$ANSIBLE_CORE_MIN" && version_ge "$ANSIBLE_CORE_MAX" "$(major_minor "$core")"; then
    pass ansible_version "ansible-core ${core} (supported ${ANSIBLE_CORE_MIN} to ${ANSIBLE_CORE_MAX})"
  else
    fail ansible_version "ansible-core ${core} is outside the supported range ${ANSIBLE_CORE_MIN} to ${ANSIBLE_CORE_MAX}"
  fi
  if [[ -n "$py" ]] && version_ge "$py" "$PYTHON_MIN"; then
    pass python_version "python ${py}"
  else
    fail python_version "Ansible runs on python ${py:-unknown}; need >= ${PYTHON_MIN}"
  fi
fi

# collections
if ((ANSIBLE_OK)); then
  col_missing=()
  for c in cyberark.pas community.general ansible.posix; do
    ansible-galaxy collection list "$c" 2>/dev/null | grep -q "^${c//./\\.} " || col_missing+=("$c")
  done
  if ((${#col_missing[@]})); then
    fail collections "missing: ${col_missing[*]} (run: ansible-galaxy collection install -r collections/requirements.yml -p collections)"
  else
    pass collections "cyberark.pas community.general ansible.posix"
  fi
fi

# repo_layout
layout_missing=()
for p in ansible.cfg collections/requirements.yml playbooks/preflight.yml roles/preflight roles/credentials scripts/common/lib/common.sh; do
  [[ -r "$p" ]] || layout_missing+=("$p")
done
if ((${#layout_missing[@]})); then
  fail repo_layout "missing or unreadable in ${REPO_ROOT}: ${layout_missing[*]}"
else
  pass repo_layout "$REPO_ROOT"
fi

# inventory_parse / inventory_hosts
if [[ ! -f "${INV}/hosts.yml" ]]; then
  fail inventory_parse "${INV}/hosts.yml not found (environments: $(find inventories -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null))"
elif ((ANSIBLE_OK)); then
  for g in murex_app oracle_db; do
    out=$(ansible -i "$INV" "$g" --list-hosts 2>&1) || true
    n=$(sed -n 's/^ *hosts (\([0-9]*\)):.*/\1/p' <<<"$out")
    if [[ "${n:-0}" -ge 1 ]]; then
      pass inventory_parse "group ${g} has ${n} host(s)"
    else
      fail inventory_parse "group ${g} has no hosts in ${INV}/hosts.yml: $(tail -n1 <<<"$out")"
    fi
  done
  if grep -qi 'change-me' "${INV}/hosts.yml"; then
    fail inventory_hosts "${INV}/hosts.yml still has CHANGE-ME placeholder hosts; put the real app VM and Oracle host names in"
  else
    pass inventory_hosts "no placeholders"
  fi
fi

# credentials
vault_needed=0
vault_ok=0
if [[ "${USE_CYBERARK,,}" == true || "${USE_CYBERARK,,}" == yes ]]; then
  if grep -qiE '^cyberark_(ccp_url|app_id):.*change[-_]me' "$MAIN_VARS"; then
    fail credentials "use_cyberark=true but cyberark_ccp_url / cyberark_app_id in ${MAIN_VARS} are still placeholders"
  else
    pass credentials "source=cyberark (CCP reachability is checked by the credentials role)"
  fi
elif [[ ! -f "$CREDS" ]]; then
  fail credentials "${CREDS} not found; copy ${CREDS}.example to it, fill it in, then: ansible-vault encrypt ${CREDS}"
else
  # shellcheck disable=SC2016 # literal vault header, not a variable
  if [[ "$(head -c 14 "$CREDS")" == '$ANSIBLE_VAULT' ]] || grep -q '!vault' "$CREDS"; then
    vault_needed=1
    if [[ -z "$VAULT_PASSWORD_FILE" ]]; then
      warn credentials "${CREDS} is vault-encrypted; run ansible-playbook with --ask-vault-pass (or pass --vault-password-file here to verify the password)"
    elif [[ ! -r "$VAULT_PASSWORD_FILE" ]]; then
      fail credentials "vault password file ${VAULT_PASSWORD_FILE} is not readable"
    elif ((ANSIBLE_OK)) && ansible-inventory -i "$INV" --vault-password-file "$VAULT_PASSWORD_FILE" --host "$(ansible -i "$INV" murex_app --list-hosts 2>/dev/null | sed -n '2p' | tr -d ' ')" >/dev/null 2>&1; then
      vault_ok=1
      pass credentials "source=file encrypted=yes vault password opens it"
    else
      fail credentials "the vault password in ${VAULT_PASSWORD_FILE} does not open ${CREDS} (or the file does not parse)"
    fi
  else
    if grep -q 'CHANGE_ME' "$CREDS"; then
      fail credentials "${CREDS} still contains CHANGE_ME values"
    else
      warn credentials "${CREDS} is plain text; fine for a throwaway test VM only. Encrypt it: ansible-vault encrypt ${CREDS}"
    fi
  fi
fi

# inventory_vars
if ((ANSIBLE_OK)) && [[ -f "${INV}/hosts.yml" ]]; then
  vault_args=()
  ((vault_ok)) && vault_args=(--vault-password-file "$VAULT_PASSWORD_FILE")
  if ((vault_needed && !vault_ok)); then
    warn inventory_vars "skipped full variable parse: needs the vault password"
  elif out=$(ansible-inventory -i "$INV" "${vault_args[@]}" --list 2>&1 >/dev/null); then
    pass inventory_vars "all group_vars parse"
  else
    fail inventory_vars "$(grep -m3 -iE 'error|warning' <<<"$out" | tr '\n' ' ' | cut -c1-400)"
  fi
fi

# run_logs
if ((LOG_FALLBACK_USED)); then
  fail run_logs "cannot create or write ${RUN_LOGS}; create it once with: sudo mkdir -p ${RUN_LOGS} && sudo chown -R $(id -un) ${LOG_BASE_DIR} (fallback log: ${LOG_FILE})"
else
  probe="${LOG_DIR}/.write-test-$$"
  if printf 'ok\n' >"$probe" 2>/dev/null && rm -f -- "$probe"; then
    pass run_logs "${LOG_DIR} writable"
  else
    fail run_logs "cannot write a test file in ${LOG_DIR}"
  fi
fi

# disk_logs / disk_stage
free_mb() {
  local d=$1
  while [[ ! -d "$d" && "$d" != / ]]; do d=$(dirname "$d"); done
  df -Pm -- "$d" | awk 'NR==2{print $4}'
}
f=$(free_mb "$RUN_LOGS")
if ((f >= MIN_FREE_MB_LOGS)); then pass disk_logs "${f}MB free for ${RUN_LOGS}"; else fail disk_logs "${f}MB free for ${RUN_LOGS}; need ${MIN_FREE_MB_LOGS}MB"; fi
if ! mkdir -p "$CONTROL_STAGE_DIR" 2>/dev/null || [[ ! -w "$CONTROL_STAGE_DIR" ]]; then
  fail disk_stage "cannot create or write control_stage_dir ${CONTROL_STAGE_DIR}"
else
  f=$(free_mb "$CONTROL_STAGE_DIR")
  if ((f >= MIN_FREE_MB_STAGE)); then pass disk_stage "${f}MB free in ${CONTROL_STAGE_DIR}"; else fail disk_stage "${f}MB free in ${CONTROL_STAGE_DIR}; need ${MIN_FREE_MB_STAGE}MB"; fi
fi

# sshpass
if command -v sshpass >/dev/null 2>&1; then
  pass sshpass "$(command -v sshpass)"
else
  warn sshpass "not installed; needed only if hosts use SSH password logins (dnf/apt install sshpass)"
fi

if ((${#FAILED[@]})); then
  die 1 "${#FAILED[@]} check(s) failed: ${FAILED[*]}. Fix them, then re-run this script before ansible-playbook"
fi
result ok "env=${MUREX_ENV}" "log=${LOG_FILE}"
