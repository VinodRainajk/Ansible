#!/usr/bin/env bash
# TEST ONLY. Integration test for Section 0 (preflight) and Section 1
# (credentials) against the stand-in hosts from setup_local_hosts.sh.
#   tests/ansible/setup_local_hosts.sh   # once, needs sudo
#   tests/ansible/run_local.sh           # KEEP=1 keeps the temp dir
# Optional: ANSIBLE_216="python3 -s /usr/bin/ansible-playbook" also runs one
# scenario with that (older) ansible-core.

# "cond && ok || bad" is intentional: ok/bad always return 0.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SECRETS=${SECRETS:-/tmp/murex-it-secrets}
# shellcheck disable=SC1090
source "$SECRETS"
cd "$REPO"
export ANSIBLE_CONFIG="$REPO/ansible.cfg"

T=$(mktemp -d)
INV="$T/inv"
OUT="$T/out"
mkdir -p "$OUT"
CCP_PID=""
cleanup() {
  [[ -n "$CCP_PID" ]] && kill "$CCP_PID" 2>/dev/null || true
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

LOGBASE=/tmp/murex-it-control
DB_PASS="Db-Admin-$(head -c 9 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
JF_TOKEN="jf-$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
VAULT_PASS_FILE="$T/vault-pass"
umask 077
printf 'it-vault-%s\n' "$(head -c 9 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')" >"$VAULT_PASS_FILE"
printf 'not-the-password\n' >"$T/wrong-vault-pass"
umask 022

pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
stamp() { date -u +%Y%m%d-%H%M%S; }

reset_inventory() {
  rm -rf "$INV"
  cp -r "$HERE/inventories/local" "$INV"
}
write_creds() { # write_creds <mx_ssh_password> [jfrog_token]
  cat >"$INV/group_vars/all/credentials.yml" <<EOF
---
mx_ssh_user: mxssh
mx_ssh_password: "$1"
ora_ssh_user: orassh
ora_ssh_password: "$ORA_PASS"
db_admin_user: mx_dba
db_admin_password: "$DB_PASS"
jfrog_user: svc-murex
jfrog_token: "${2:-$JF_TOKEN}"
EOF
}

# pb <label> <want: 0|nonzero> <run_id> -- ansible-playbook args...
pb() {
  local label=$1 want=$2 rid=$3 rc=0
  shift 4
  # Fresh SSH ControlPersist sockets per run, so a login is really re-done.
  ANSIBLE_SSH_CONTROL_PATH_DIR="$T/cp/$label" "${PLAYBOOK_CMD[@]}" -i "$INV" -e "run_id=$rid" "$@" >"$OUT/$label.txt" 2>&1 || rc=$?
  if [[ "$want" == 0 && $rc == 0 ]] || [[ "$want" == nonzero && $rc != 0 ]]; then
    ok "$label (rc=$rc)"
  else
    bad "$label (rc=$rc, want $want)"
    tail -n 25 "$OUT/$label.txt" | sed 's/^/    /'
  fi
}
# has <label> <file> <extended regex>
has() {
  if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else
    bad "$1 (no /$3/ in $2)"
  fi
}
count_is() { # count_is <label> <file> <regex> <n>
  local n
  n=$(grep -cE -- "$3" "$2" 2>/dev/null || true)
  if [[ "$n" == "$4" ]]; then ok "$1"; else bad "$1 (found $n, want $4)"; fi
}
runlog() { echo "$LOGBASE/run_logs/$1/run.log"; }

PLAYBOOK_CMD=(ansible-playbook)

echo "== check_control_node.sh"
reset_inventory
write_creds "$MX_PASS"
rc=0
scripts/common/preflight/check_control_node.sh --env local --inventory-dir "$INV" >"$OUT/check-plain.txt" 2>&1 || rc=$?
((rc == 0)) && ok "control node check passes (plain credentials)" || { bad "control node check (rc=$rc)"; grep -E 'ERROR|WARN' "$OUT/check-plain.txt" | sed 's/^/    /'; }
has "control node check warns about plain text" "$OUT/check-plain.txt" 'WARN .* check=credentials detail=.*plain text'
has "control node check log line format" "$OUT/check-plain.txt" '^[0-9-]{10}T[0-9:]{8}Z INFO local-check-control-node-[0-9]{8}-[0-9]{6} preflight host=.* check=ansible_version ok'

sudo mkdir -p /var/log/murex-it-readonly && sudo chown root:root /var/log/murex-it-readonly && sudo chmod 0755 /var/log/murex-it-readonly
rc=0
scripts/common/preflight/check_control_node.sh --env local --inventory-dir "$INV" --log-base-dir /var/log/murex-it-readonly >"$OUT/check-ro.txt" 2>&1 || rc=$?
((rc == 1)) && ok "control node check fails on an unwritable log_base_dir" || bad "unwritable log dir check (rc=$rc)"
fb=$(sed -n 's/.*logging to \(\/tmp\/murex-ansible-preflight-[^ ]*\.log\).*/\1/p' "$OUT/check-ro.txt" | head -n1)
has "check script wrote the /tmp fallback log" "${fb:-/nonexistent}" 'ERROR local-check-control-node-.* preflight host=.* check=run_logs detail=cannot create or write /var/log/murex-it-readonly/run_logs'

echo "== preflight + credentials, plain file"
rid="it-plain-$(stamp)"
pb preflight-plain 0 "$rid" -- playbooks/preflight.yml
has "run log has run started" "$(runlog "$rid")" "INFO $rid preflight run started env=local playbook=preflight"
has "app host preflight ok" "$(runlog "$rid")" "INFO $rid preflight host=app-local check=all ok login=mxssh script_user=murex"
has "db host preflight ok" "$(runlog "$rid")" "INFO $rid preflight host=db-local check=all ok login=orassh script_user=oracle"
[[ "$(stat -c %U /tmp/murex-it-app/script_logs/"$rid")" == murex && "$(stat -c %U /tmp/murex-it-db/script_logs/"$rid")" == oracle ]] &&
  ok "script_logs/<run_id> owned by murex (app) and oracle (db)" || bad "script_logs ownership"
bad_lines=$(grep -cvE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z (INFO|WARN|ERROR) [A-Za-z0-9._-]+ [a-z_]+ ' "$(runlog "$rid")" || true)
((bad_lines == 0)) && ok "every run log line is '<ts> <LEVEL> <run_id> <step> <message>'" || bad "$bad_lines malformed run log line(s)"

rid="it-creds-plain-$(stamp)"
pb credentials-plain 0 "$rid" -- playbooks/credentials.yml
has "file source logged as not encrypted" "$(runlog "$rid")" "INFO $rid credentials source=file env=local file=.* encrypted=no"
has "plain-text warning logged" "$(runlog "$rid")" "WARN $rid credentials .*plain text is for a throwaway test VM only"
has "loaded 8 keys" "$(runlog "$rid")" "INFO $rid credentials source=file env=local loaded=8 keys"
has "credentials cleared at the end" "$(runlog "$rid")" "INFO $rid credentials credentials cleared"

echo "== preflight + credentials, vault-encrypted file"
ansible-vault encrypt --vault-password-file "$VAULT_PASS_FILE" "$INV/group_vars/all/credentials.yml" >/dev/null 2>&1
head -c 14 "$INV/group_vars/all/credentials.yml" | grep -q '^\$ANSIBLE_VAULT' && ok "credentials.yml is vault-encrypted" || bad "vault encrypt"
rc=0
scripts/common/preflight/check_control_node.sh --env local --inventory-dir "$INV" --vault-password-file "$VAULT_PASS_FILE" >"$OUT/check-vault.txt" 2>&1 || rc=$?
((rc == 0)) && ok "control node check passes with the vault password" || bad "check with vault (rc=$rc)"
has "check script opened the vault" "$OUT/check-vault.txt" 'check=credentials ok detail=source=file encrypted=yes vault password opens it'
rc=0
scripts/common/preflight/check_control_node.sh --env local --inventory-dir "$INV" --vault-password-file "$T/wrong-vault-pass" >"$OUT/check-vault-wrong.txt" 2>&1 || rc=$?
((rc == 1)) && ok "control node check fails with a wrong vault password" || bad "wrong vault password check (rc=$rc)"

rid="it-creds-vault-$(stamp)"
pb credentials-vault 0 "$rid" -- playbooks/credentials.yml --vault-password-file "$VAULT_PASS_FILE"
has "file source logged as encrypted" "$(runlog "$rid")" "INFO $rid credentials source=file env=local file=.* encrypted=yes"
has "loaded 8 keys from the vault" "$(runlog "$rid")" "INFO $rid credentials source=file env=local loaded=8 keys"
has "credentials cleared (vault)" "$(runlog "$rid")" "INFO $rid credentials credentials cleared"
pb credentials-vault-no-password nonzero "it-novault-$(stamp)" -- playbooks/credentials.yml
has "missing vault password is reported" "$OUT/credentials-vault-no-password.txt" '(?i)vault|decrypt'

echo "== stubs and orchestrator"
rid="it-stub-$(stamp)"
pb stub-app-validate nonzero "$rid" -- playbooks/app/validate.yml --vault-password-file "$VAULT_PASS_FILE"
has "stub says not implemented" "$(runlog "$rid")" "WARN $rid run not implemented yet: Section 2 \(Validate\) for the app VM"
has "stub clears credentials" "$(runlog "$rid")" "INFO $rid credentials credentials cleared"
rid="it-orch-$(stamp)"
pb orchestrator-validate nonzero "$rid" -- playbooks/validate.yml --vault-password-file "$VAULT_PASS_FILE"
count_is "orchestrator runs preflight once" "$(runlog "$rid")" "preflight run started" 1
count_is "orchestrator loads credentials once" "$(runlog "$rid")" "credentials source=file env=local loaded=8 keys" 1
has "orchestrator stops at the first stub (db)" "$(runlog "$rid")" "not implemented yet: Section 2 \(Validate\) for the Oracle host"

echo "== forced failures"
rid="it-ro-$(stamp)"
pb unwritable-log-dir nonzero "$rid" -- playbooks/preflight.yml --vault-password-file "$VAULT_PASS_FILE" -e log_base_dir=/var/log/murex-it-readonly
has "fallback log in /tmp" "/tmp/murex-ansible-preflight-$rid.log" "ERROR $rid preflight host=localhost check=run_logs detail=cannot create or write /var/log/murex-it-readonly/run_logs/$rid"
has "console shows the failure" "$OUT/unwritable-log-dir.txt" "ERROR $rid preflight host=localhost check=run_logs"
[[ ! -e /tmp/murex-it-app/script_logs/"$rid" ]] && ok "no host was touched after the control node failed" || bad "host touched after control failure"

reset_inventory
write_creds "wrong-password"
rid="it-badssh-$(stamp)"
pb bad-ssh-password nonzero "$rid" -- playbooks/credentials.yml
has "bad SSH password -> ERROR check=ssh" "$(runlog "$rid")" "ERROR $rid preflight host=app-local check=ssh detail=.*(Permission denied|Invalid/incorrect password|Authentication)"
has "the other host still finishes its own checks" "$(runlog "$rid")" "INFO $rid preflight host=db-local check=all ok"
has "run stops with the failed host list" "$(runlog "$rid")" "ERROR $rid preflight preflight failed hosts=app-local ok_hosts=db-local"
count_is "credentials never ran after the preflight failure" "$(runlog "$rid")" " credentials " 0

write_creds "$MX_PASS" CHANGE_ME
rid="it-placeholder-$(stamp)"
pb placeholder-credential nonzero "$rid" -- playbooks/credentials.yml
has "placeholder -> ERROR credentials check=complete" "$(runlog "$rid")" "ERROR $rid credentials source=file env=local check=complete detail=.*still CHANGE_ME: jfrog_token"
has "cleared after a credentials failure" "$(runlog "$rid")" "INFO $rid credentials credentials cleared"

echo "== CyberArk (mock CCP)"
reset_inventory
cat >"$T/ccp.json" <<EOF
{"MUREX_IT_SAFE/it-murex_app_ssh":   {"UserName": "mxssh",     "Content": "$MX_PASS"},
 "MUREX_IT_SAFE/it-oracle_host_ssh": {"UserName": "orassh",    "Content": "$ORA_PASS"},
 "MUREX_IT_SAFE/it-oracle_db_admin": {"UserName": "mx_dba",    "Content": "$DB_PASS"},
 "MUREX_IT_SAFE/it-jfrog_token":     {"UserName": "svc-murex", "Content": "$JF_TOKEN"}}
EOF
python3 "$HERE/mock_ccp.py" 18443 "$T/ccp.json" MUREX_IT 2>"$OUT/mock_ccp.log" &
CCP_PID=$!
sleep 1
rid="it-cyberark-$(stamp)"
pb cyberark-ok 0 "$rid" -- playbooks/credentials.yml -e use_cyberark=true
has "CCP connect logged" "$(runlog "$rid")" "INFO $rid credentials source=cyberark connect=ok url=127.0.0.1 app_id=MUREX_IT http_status=400"
count_is "one fetched line per object" "$(runlog "$rid")" "INFO $rid credentials source=cyberark fetched object=" 4
has "cyberark loaded 8 keys" "$(runlog "$rid")" "INFO $rid credentials source=cyberark env=local loaded=8 keys"
has "cyberark cleared" "$(runlog "$rid")" "INFO $rid credentials credentials cleared"

rid="it-cyberark-missing-$(stamp)"
pb cyberark-missing-object nonzero "$rid" -- playbooks/credentials.yml -e use_cyberark=true \
  -e '{"cyberark_accounts":[{"name":"jfrog","safe":"MUREX_IT_SAFE","object":"it-does-not-exist","user_var":"jfrog_user","secret_var":"jfrog_token"}]}'
has "missing object -> ERROR source=cyberark" "$(runlog "$rid")" "ERROR $rid credentials source=cyberark env=local check=cyberark_fetch detail=source=cyberark object=it-does-not-exist .*http_status=404"
has "cleared after a CyberArk failure" "$(runlog "$rid")" "INFO $rid credentials credentials cleared"

rid="it-cyberark-down-$(stamp)"
pb cyberark-unreachable nonzero "$rid" -- playbooks/credentials.yml -e use_cyberark=true -e cyberark_ccp_url=http://127.0.0.1:18444 -e cyberark_timeout=3
has "CCP down -> ERROR check=cyberark_connect" "$(runlog "$rid")" "ERROR $rid credentials source=cyberark env=local check=cyberark_connect"

if [[ -n "${ANSIBLE_216:-}" ]]; then
  echo "== older ansible-core"
  reset_inventory
  write_creds "$MX_PASS"
  read -r -a PLAYBOOK_CMD <<<"$ANSIBLE_216"
  ver=$("${PLAYBOOK_CMD[@]}" --version | head -n1)
  rid="it-old-core-$(stamp)"
  pb "credentials-${ver// /_}" 0 "$rid" -- playbooks/credentials.yml
  has "older core loaded 8 keys" "$(runlog "$rid")" "loaded=8 keys"
  PLAYBOOK_CMD=(ansible-playbook)
fi

echo "== secrets"
leaks=0
for s in "$MX_PASS" "$ORA_PASS" "$DB_PASS" "$JF_TOKEN"; do
  if grep -rqF -- "$s" "$OUT" "$LOGBASE/run_logs" /tmp/murex-it-app /tmp/murex-it-db /tmp/murex-ansible-preflight-it-*.log 2>/dev/null; then
    leaks=$((leaks + 1))
  fi
done
((leaks == 0)) && ok "no password or token in any console output or log file" || bad "$leaks secret(s) found in output or logs"

echo
echo "passed=${pass} failed=${fail}"
((fail == 0))
