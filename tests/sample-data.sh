#!/usr/bin/env bash
# Sample data for trying the plugin or reviewing it without touching real
# logs: three days of made-up ABC-* timers in a project named acme-shop (from
# the worklog-timer plugin's own sample), one worklog already logged and a
# config for a made-up Plane site. The local figures work on it; the commands
# that call Plane need a real site and token.
#   bash tests/sample-data.sh DIR
# Then, in the same shell:
#   export TIMER_HOME=DIR PLANE_HOME=DIR/plane TIMER_PROJECT=acme-shop
#   plane.sh day yesterday; plane.sh month; plane.sh figures ABC-118
set -euo pipefail

dir="${1:?usage: bash tests/sample-data.sh DIR}"
timer_sample="$(dirname "$(command -v timer.sh 2>/dev/null || echo "${TIMER_BIN:?set TIMER_BIN or put timer.sh on PATH}")")/../tests/sample-data.sh"
if [ -r "$timer_sample" ]; then
    bash "$timer_sample" "$dir" >/dev/null
else
    echo "worklog-timer's tests/sample-data.sh not found next to timer.sh" >&2
    exit 1
fi
mkdir -p "$dir/plane/logs"
now=$(date +%s)
# ABC-118: 3h of its time logged as a worklog comment, started the day before yesterday.
printf 'ABC-118\t10800\t3f1c0d2e-sample\t%s\t-\tInvestigation and fix of the export\t%s\n' \
    "$now" "$((now - 2 * 86400 - 4 * 3600 + 210 * 60))" > "$dir/plane/logs/acme-shop.tsv"
cat > "$dir/plane/config.json" <<'JSON'
{
  "baseUrl": "https://plane.example.com",
  "commentLanguage": "English",
  "worklogLanguage": "English",
  "transitions": { "start": ["In Progress"], "close": ["Deployed", "Ready for testing"], "done": ["Done"] },
  "workspaces": { "acme": { "projects": { "ABC": "00000000-0000-0000-0000-000000000000" } } }
}
JSON
echo "Sample data in $dir"
echo "export TIMER_HOME='$dir' PLANE_HOME='$dir/plane' TIMER_PROJECT=acme-shop"
