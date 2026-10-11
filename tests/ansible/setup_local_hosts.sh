#!/usr/bin/env bash
# TEST ONLY. Turns this machine into two stand-in SSH hosts for the
# integration test (tests/ansible/run_local.sh):
#   app-local  127.0.0.1:22    login mxssh   (password, sudo needs the password)
#   db-local   127.0.0.1:2222  login orassh  (password, sudo needs the password)
# plus run users murex (group murex) and oracle (group oinstall), and an SSH
# key for the current user (used before CyberArk credentials are loaded).
# Needs sudo, openssh-server and sshpass. Never run this on a real server.
set -euo pipefail
SECRETS=${SECRETS:-/tmp/murex-it-secrets}

command -v sshpass >/dev/null || { echo "install sshpass first"; exit 1; }
[[ -x /usr/sbin/sshd ]] || { echo "install openssh-server first"; exit 1; }

umask 077
if [[ ! -f "$SECRETS" ]]; then
  {
    echo "MX_PASS=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)Aa1"
    echo "ORA_PASS=$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)Bb2"
  } >"$SECRETS"
fi
# shellcheck disable=SC1090
source "$SECRETS"

getent group murex >/dev/null || sudo groupadd murex
getent group oinstall >/dev/null || sudo groupadd oinstall
id murex >/dev/null 2>&1 || sudo useradd -m -g murex -s /bin/bash murex
id oracle >/dev/null 2>&1 || sudo useradd -m -g oinstall -s /bin/bash oracle
for u in mxssh orassh; do
  id "$u" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash "$u"
done
echo "mxssh:${MX_PASS}" | sudo chpasswd
echo "orassh:${ORA_PASS}" | sudo chpasswd
printf 'mxssh ALL=(ALL) ALL\norassh ALL=(ALL) ALL\n' | sudo tee /etc/sudoers.d/90-murex-it >/dev/null
sudo chmod 0440 /etc/sudoers.d/90-murex-it

printf 'Port 22\nPort 2222\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\nUsePAM yes\n' |
  sudo tee /etc/ssh/sshd_config.d/00-murex-it.conf >/dev/null
sudo ssh-keygen -A >/dev/null
sudo mkdir -p /run/sshd
if pgrep -x sshd >/dev/null; then sudo pkill -HUP -x sshd; else sudo /usr/sbin/sshd; fi

mkdir -p ~/.ssh
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
grep -qF "$(cat ~/.ssh/id_ed25519.pub)" ~/.ssh/authorized_keys 2>/dev/null || cat ~/.ssh/id_ed25519.pub >>~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

sleep 1
sshpass -p "$MX_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 mxssh@127.0.0.1 true
sshpass -p "$ORA_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 2222 orassh@127.0.0.1 true
echo "stand-in hosts ready (passwords in ${SECRETS})"
