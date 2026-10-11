#!/usr/bin/env bash
# Overlay this environment's config files onto MX_HOME and check that no
# other environment's hostnames survived from the gold copy.
set -euo pipefail
SCRIPTS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../common/lib/common.sh
source "${SCRIPTS_ROOT}/common/lib/common.sh"
# shellcheck source=../lib/mx.sh
source "${SCRIPTS_ROOT}/app/lib/mx.sh"

usage() {
  cat <<'EOF'
Usage: mx_config_overlay.sh --overlay-dir DIR [--forbidden-patterns "re1|re2"] [--dry-run] [--run-id ID] [--mx-home DIR]

OVERLAY_DIR mirrors MX_HOME relative paths and holds files already rendered
for this environment (by Ansible templates). Each file that differs from the
one in MX_HOME is backed up to MX_HOME/.config-backup/<RUN_ID>/ and replaced;
identical files are left alone. Nothing differs -> RESULT status=ok.
Fails if any overlay file still contains "{{" or "}}" (unrendered template).
FORBIDDEN_PATTERNS: extended regex (e.g. "mxdev01|devdb01\.corp") checked
after the overlay across CONFIG_SCAN_GLOBS under MX_HOME (default
"*.xml *.properties *.cfg *.conf *.ini *.sh"); any hit fails the step.
EOF
}

: "${OVERLAY_DIR:=}"
: "${FORBIDDEN_PATTERNS:=}"
: "${CONFIG_SCAN_GLOBS:=*.xml *.properties *.cfg *.conf *.ini *.sh}"
SCRIPT_VARS=("${MX_VARS[@]}" OVERLAY_DIR FORBIDDEN_PATTERNS CONFIG_SCAN_GLOBS)
init_script mx_config_overlay "$@"
mx_require_home_var
require_vars OVERLAY_DIR
acquire_lock mx-app

[[ -d "$OVERLAY_DIR" ]] || die 2 "OVERLAY_DIR ${OVERLAY_DIR} is not a directory"
[[ -f "${MX_HOME}/${MX_HOME_MARKER}" ]] || die "no MX install at ${MX_HOME} (missing ${MX_HOME_MARKER})"

unrendered=$(grep -rlE '\{\{|\}\}' -- "$OVERLAY_DIR" || true)
[[ -z "$unrendered" ]] || die "unrendered template markers in: $(tr '\n' ' ' <<<"$unrendered")"

mx_probe
[[ "$MX_STATE" == stopped ]] || log_warn "MX is ${MX_STATE}; config changes take effect after a restart"

backup_root="${MX_HOME}/.config-backup/${RUN_ID}"
changed_files=0
while IFS= read -r rel; do
  src="${OVERLAY_DIR}/${rel}"
  dst="${MX_HOME}/${rel}"
  if [[ -f "$dst" ]] && cmp -s -- "$src" "$dst"; then
    continue
  fi
  if [[ -f "$dst" && ! -e "${backup_root}/${rel}" ]]; then
    run_or_die install -D -p -m 0640 -- "$dst" "${backup_root}/${rel}"
  fi
  mode=0640
  [[ -x "$src" ]] && mode=0750
  [[ -f "$dst" ]] && mode=$(stat -c %a "$dst")
  run_or_die install -D -m "$mode" -- "$src" "$dst"
  log_info "config updated: ${rel}"
  changed_files=$((changed_files + 1))
done < <(cd "$OVERLAY_DIR" && find . -type f | sed 's|^\./||' | sort)

if ((changed_files)); then
  mark_changed
  mx_chown "$MX_HOME"
fi
log_info "${changed_files} config file(s) changed"

if [[ -n "$FORBIDDEN_PATTERNS" ]]; then
  includes=()
  for g in $CONFIG_SCAN_GLOBS; do
    includes+=("--include=${g}")
  done
  hits=$(grep -rIlE "${includes[@]}" --exclude-dir=.config-backup --exclude-dir=.patches \
    --exclude-dir=logs -- "$FORBIDDEN_PATTERNS" "$MX_HOME" || true)
  if [[ -n "$hits" ]]; then
    level=ERROR
    ((DRY_RUN)) && level=WARN
    while IFS= read -r f; do
      log "$level" "forbidden pattern found in ${f}: $(grep -nE -m3 -- "$FORBIDDEN_PATTERNS" "$f" | cut -c1-200 | paste -sd';' -)"
    done <<<"$hits"
    ((DRY_RUN)) && log_warn "DRY-RUN: these hits may disappear once the overlay is really applied"
    ((DRY_RUN)) || die "$(wc -l <<<"$hits") config file(s) still reference another environment"
  else
    log_info "no forbidden patterns found"
  fi
fi

result auto "changed_files=${changed_files}"
