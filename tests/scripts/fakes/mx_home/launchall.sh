#!/usr/bin/env bash
# Fake Murex launcher: one long-lived process per service whose command line
# contains MX_HOME and the service name, like the real JVMs are assumed to.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
for svc in ${MX_SERVICES:-fileserver xmlserver launcher}; do
  if ! pgrep -f -- "${here}.*${svc}" >/dev/null; then
    nohup setsid bash -c "exec -a 'java -Dmx.home=${here} -Dmx.service=${svc}' sleep 86400" >/dev/null 2>&1 &
  fi
done
echo "launched"
