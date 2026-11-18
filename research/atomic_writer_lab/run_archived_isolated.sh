#!/usr/bin/env bash
# Synthetic LAB ONLY. The separate +14 fixture must be extracted from the
# pinned archive; the browser probe independently verifies every file hash.
# Linux, sudo -n, unshare, setpriv, ip, Node and pinned Playwright required.
# Usage: NODE_PATH=/... PLAYWRIGHT_BROWSERS_PATH=/... \
#   ./run_archived_isolated.sh chromium|firefox FIXTURE_DIR NEW_REPORT.json
set -euo pipefail
if [[ $# -ne 3 || $(id -u) -eq 0 ]]; then
  echo 'Run unprivileged: run_archived_isolated.sh chromium|firefox FIXTURE_DIR NEW_REPORT.json' >&2; exit 2
fi
engine=$1
[[ $engine == chromium || $engine == firefox ]] || { echo 'Unsupported browser' >&2; exit 2; }
fixture=$(realpath -e -- "$2")
out=$(realpath -m -- "$3")
[[ -d "$fixture" && ! -e "$out" && ! -L "$out" && -d $(dirname -- "$out") ]] || { echo 'Invalid fixture or report' >&2; exit 2; }
: "${NODE_PATH:?set NODE_PATH to the pinned Playwright node_modules directory}"
: "${PLAYWRIGHT_BROWSERS_PATH:?set PLAYWRIGHT_BROWSERS_PATH to the pinned browser directory}"
node_path=$(realpath -e -- "$NODE_PATH")
browsers=$(realpath -e -- "$PLAYWRIGHT_BROWSERS_PATH")
[[ -d "$node_path/playwright" && -d "$browsers" ]] || { echo 'Playwright or browser directory missing' >&2; exit 2; }
node=$(command -v node)
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
probe="$here/archived_v14_mixed_probe.cjs"
uid=$(id -u); gid=$(id -g)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fitness-synthetic-archive.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
# Separate network stack, loopback only; drop privileges and inherited environment.
sudo -n unshare -n -- /bin/bash -c '
  set -euo pipefail
  ip link set lo up
  exec setpriv --reuid="$1" --regid="$2" --clear-groups \
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$3" TMPDIR="$3" LANG=C.UTF-8 \
    NODE_PATH="$4" PLAYWRIGHT_BROWSERS_PATH="$5" "$6" "$7" "$8" "$9" "${10}"
' _ "$uid" "$gid" "$scratch" "$node_path" "$browsers" "$node" "$probe" "$engine" "$fixture" "$out"
