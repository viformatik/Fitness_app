#!/usr/bin/env bash
# Disposable synthetic profiles only. Do not point this at a real user profile.
# Requires Linux, sudo -n, unshare, setpriv, ip, Node, and pinned Playwright browsers.
# NODE_PATH=... PLAYWRIGHT_BROWSERS_PATH=... bash run_isolated.sh chromium|firefox NEW_REPORT.json
set -euo pipefail
if [[ $# -ne 2 || $(id -u) -eq 0 ]]; then
  echo 'Run unprivileged: run_isolated.sh chromium|firefox NEW_REPORT.json' >&2; exit 2
fi
engine=$1
[[ $engine == chromium || $engine == firefox ]] || { echo 'Unsupported browser' >&2; exit 2; }
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo=$(cd -- "$here/../.." && pwd -P)
candidate=$(realpath -e -- "$repo/candidate/build/web")
out=$(realpath -m -- "$2")
[[ ! -e "$out" && ! -L "$out" && -d $(dirname -- "$out") && "$out" != "$candidate"/* ]] || {
  echo 'Invalid report path' >&2; exit 2;
}
: "${NODE_PATH:?set NODE_PATH to pinned Playwright node_modules}"
: "${PLAYWRIGHT_BROWSERS_PATH:?set PLAYWRIGHT_BROWSERS_PATH to pinned browser directory}"
node_path=$(realpath -e -- "$NODE_PATH"); browsers=$(realpath -e -- "$PLAYWRIGHT_BROWSERS_PATH")
[[ -d "$node_path/playwright" && -d "$browsers" ]] || { echo 'Playwright or browsers missing' >&2; exit 2; }
node=$(command -v node); uid=$(id -u); gid=$(id -g)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fitness-sidecar-lab.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
sudo -n unshare -n -- /bin/bash -c '
  set -euo pipefail
  ip link set lo up
  exec setpriv --reuid="$1" --regid="$2" --clear-groups \
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$3" TMPDIR="$3" LANG=C.UTF-8 \
    NODE_PATH="$4" PLAYWRIGHT_BROWSERS_PATH="$5" "$6" "$7" "$8" "$9" "${10}"
' _ "$uid" "$gid" "$scratch" "$node_path" "$browsers" "$node" "$here/sidecar_probe.cjs" "$engine" "$candidate" "$out"
