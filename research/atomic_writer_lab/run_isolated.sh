#!/usr/bin/env bash
# Disposable synthetic lab only. Requires Linux, sudo -n, unshare, ip, setpriv,
# Node and the pinned Playwright browsers. Nothing is deployed or migrated.
# Usage: NODE_PATH=/.../node_modules PLAYWRIGHT_BROWSERS_PATH=/.../browsers \
#          ./run_isolated.sh chromium|firefox /new/report.json
set -euo pipefail
if [[ $# -ne 2 || $(id -u) -eq 0 ]]; then
  echo 'Run as a non-root user: run_isolated.sh chromium|firefox NEW_REPORT.json' >&2; exit 2
fi
engine=$1
[[ $engine == chromium || $engine == firefox ]] || { echo 'Unsupported browser' >&2; exit 2; }
out=$(realpath -m -- "$2")
[[ ! -e "$out" && ! -L "$out" && -d $(dirname -- "$out") ]] || { echo 'Report path must be new and have an existing parent' >&2; exit 2; }
: "${NODE_PATH:?set NODE_PATH to the pinned Playwright node_modules directory}"
: "${PLAYWRIGHT_BROWSERS_PATH:?set PLAYWRIGHT_BROWSERS_PATH to the pinned browser directory}"
node_path=$(realpath -e -- "$NODE_PATH")
browsers=$(realpath -e -- "$PLAYWRIGHT_BROWSERS_PATH")
[[ -d "$node_path/playwright" && -d "$browsers" ]] || { echo 'Playwright or browser directory missing' >&2; exit 2; }
node=$(command -v node)
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
probe="$here/synthetic_idb_probe.cjs"
uid=$(id -u); gid=$(id -g)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fitness-synthetic-lab.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
# The namespace has its own network stack. Turn on only lo, then drop root,
# supplementary groups and inherited environment before executing the probe.
sudo -n unshare -n -- /bin/bash -c '
  set -euo pipefail
  ip link set lo up
  exec setpriv --reuid="$1" --regid="$2" --clear-groups \
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$3" TMPDIR="$3" LANG=C.UTF-8 \
    NODE_PATH="$4" PLAYWRIGHT_BROWSERS_PATH="$5" "$6" "$7" "$8" "$9"
' _ "$uid" "$gid" "$scratch" "$node_path" "$browsers" "$node" "$probe" "$engine" "$out"
