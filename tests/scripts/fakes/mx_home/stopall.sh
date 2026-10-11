#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
pkill -f -- "-Dmx.home=${here} " || true
echo "stopped"
