#!/usr/bin/env bash
# LAB ONLY. Read before use. Requires Linux, sudo without prompt, unshare, ip,
# runuser, Playwright 1.56.1 and its matching browser. Creates a new network
# namespace as root, then drops back to the caller before executing Node.
# Usage: NODE_PATH=... PLAYWRIGHT_BROWSERS_PATH=... FITNESS_PROBE=fence|race ./run_isolated.sh chromium|firefox /absolute/fixture /new/report.json
set -euo pipefail
if [[ $# -ne 3 || $(id -u) -eq 0 ]]; then
  echo 'Use as an unprivileged user: run_isolated.sh chromium|firefox FIXTURE_DIR NEW_REPORT.json' >&2; exit 2
fi
engine=$1; fixture=$(realpath -e -- "$2"); report=$(realpath -m -- "$3")
[[ $engine == chromium || $engine == firefox ]] || { echo 'Unsupported browser' >&2; exit 2; }
[[ -d $fixture && ! -e $report && ! -L $report && -d $(dirname "$report") ]] || { echo 'Invalid fixture or report path' >&2; exit 2; }
: "${NODE_PATH:?set NODE_PATH to the pinned Playwright node_modules}"
: "${PLAYWRIGHT_BROWSERS_PATH:?set PLAYWRIGHT_BROWSERS_PATH to the pinned browser cache}"
node=$(command -v node)
case ${FITNESS_PROBE:-fence} in
  fence) source_file=offline_fence_probe.cjs ;;
  race) source_file=offline_stale_race_probe.cjs ;;
  *) echo 'Unsupported FITNESS_PROBE (use fence or race)' >&2; exit 2 ;;
esac
script=$(realpath -e -- "$(dirname "$0")/$source_file")
user=$(id -un)
sudo -n unshare --net -- bash -c '
  set -euo pipefail
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  ip link set lo up
  [[ $(ip -o link show | wc -l) -eq 1 && -z $(ip route show) && -z $(ip -6 route show) ]] || { echo "Not loopback-only" >&2; exit 1; }
  exec runuser -u "$1" -- env HOME="$2" NODE_PATH="$3" PLAYWRIGHT_BROWSERS_PATH="$4" FITNESS_V14_FIXTURE="$5" FITNESS_BROWSER="$6" FITNESS_REPORT="$7" "$8" "$9"
' _ "$user" "$HOME" "$NODE_PATH" "$PLAYWRIGHT_BROWSERS_PATH" "$fixture" "$engine" "$report" "$node" "$script"
