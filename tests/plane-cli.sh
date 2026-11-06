#!/usr/bin/env bash
# End-to-end checks of bin/plane.sh against throwaway logs and a fake Plane API
# (tests/fake-plane/curl, put first on PATH), so the script can be tested on every
# platform CI offers (Linux, macOS, Windows/Git Bash).
#   bash tests/plane-cli.sh
# Needs jq, and timer.sh from the worklog-timer plugin: TIMER_BIN, else timer.sh on
# PATH, else ../claude-timer/bin/timer.sh next to this repository.
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
P="$HERE/bin/plane.sh"
if [ -z "${TIMER_BIN:-}" ]; then
    TIMER_BIN=$(command -v timer.sh 2>/dev/null || true)
    [ -z "$TIMER_BIN" ] && [ -x "$HERE/../claude-timer/bin/timer.sh" ] && TIMER_BIN="$HERE/../claude-timer/bin/timer.sh"
fi
[ -n "$TIMER_BIN" ] && [ -x "$TIMER_BIN" ] || { echo "timer.sh not found; set TIMER_BIN"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# A folder with a space, to catch unquoted paths.
export PLANE_HOME="$TMP/plane home" TIMER_HOME="$TMP/timer home" FAKE_PLANE_DIR="$TMP/fake"
export TIMER_BIN TIMER_PROJECT=ci TIMER_SESSION_ID=ci-session TZ=UTC PLANE_RETRY_WAIT=0
export CLAUDE_CONFIG_DIR="$TMP/claude"
export PATH="$HERE/tests/fake-plane:$PATH"
chmod +x "$HERE/tests/fake-plane/curl" 2>/dev/null
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID TIMER_SESSION_NAME KEY_PREFIX_INCLUDE KEY_PREFIX_EXCLUDE \
    JIRA_SESSION_TASK PLANE_API_KEY FAKE_PLANE_FAIL
mkdir -p "$FAKE_PLANE_DIR"
TOKEN="plane_api_ci0123456789"

fails=0
out=""
run() {
    local name=$1 want=$2 code
    shift 2
    out=$(bash "$P" "$@" 2>&1 </dev/null); code=$?
    check "$name" "$want" "$code"
}
# run_in TEXT NAME WANT ARGS...: the same with TEXT on stdin.
run_in() {
    local text=$1 name=$2 want=$3 code
    shift 3
    out=$(printf '%s' "$text" | bash "$P" "$@" 2>&1); code=$?
    check "$name" "$want" "$code"
}
check() {
    if [ "$3" = "$2" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: exit $3, expected $2"
        printf '%s\n' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    fi
}
has() {
    if printf '%s\n' "$out" | grep -qF -- "$1"; then
        echo "ok     has '$1'"
    else
        echo "FAIL   no '$1' in:"
        printf '%s\n' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    fi
}
hasnt() {
    if printf '%s\n' "$out" | grep -qF -- "$1"; then
        echo "FAIL   unexpected '$1' in:"
        printf '%s\n' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    else
        echo "ok     no '$1'"
    fi
}
requests() { out=$(cat "$FAKE_PLANE_DIR/requests.log" 2>/dev/null); }

# Timer log, UTC:
#   ABC-1  2026-09-07 09:00-10:10 (70m), 2026-09-08 14:00-14:20 (20m)
#   XYZ-9  2026-09-08 14:00-14:20 (another tracker's key)
mkdir -p "$TIMER_HOME/logs"
{
    printf 'ABC-1\tSTART\t1788771600\t-\nABC-1\tSTOP\t1788775800\t-\n'
    printf 'ABC-1\tSTART\t1788876000\t-\nABC-1\tSTOP\t1788877200\t-\n'
    printf 'XYZ-9\tSTART\t1788876000\t-\nXYZ-9\tSTOP\t1788877200\t-\n'
} > "$TIMER_HOME/logs/ci.tsv"

echo "== setup"
run "help" 0 help;                                 has "plane.sh init BASE_URL"; hasnt "set -uo"
run "config missing" 1 config;                     has "plane.sh init"
run "issue without config" 1 issue ABC-1;          has "plane.sh init"
run "init bad url" 1 init plane.example.com
run "init" 0 init https://plane.example.com/;      has "Wrote"
run "init again" 1 init https://plane.example.com; has "exists already"
run "key before a workspace" 1 key ABC-1;          has "add-workspace"
run "add-workspace without token" 1 add-workspace acme; has "No Plane API token"
printf '%s\n' "$TOKEN" > "$PLANE_HOME/token"
run "add-workspace bad slug" 1 add-workspace 'a b'
run "add-workspace unknown prefix" 1 add-workspace acme NOPE; has "No matching projects"
run "add-workspace" 0 add-workspace acme abc;     has "project=ABC p1"; hasnt "OPS"
run "config" 0 config
has "base_url=https://plane.example.com"; has "api_url=https://plane.example.com"; has "prefixes=ABC"
has "comment_language=English"; has "token=$PLANE_HOME/token (present)"; hasnt "$TOKEN"
PLANE_API_KEY="$TOKEN" run "config, token from env" 0 config; has "token=PLANE_API_KEY"; hasnt "$TOKEN"
PLANE_HOME="$TMP/cloud" run "init Plane Cloud" 0 init https://app.plane.so
PLANE_HOME="$TMP/cloud" run "Plane Cloud API" 0 config; has "api_url=https://api.plane.so"
run "check" 0 check;                               has "workspace=acme user=Me"; has "prefixes=ABC:acme"; hasnt "MISSING"

echo "== keys"
run "key" 0 key abc-1;                             has "ABC-1"
run "key of another tracker" 1 key XYZ-9;          has "not a Plane key"
run "key, nothing" 1 key;                          has "/plane <action> KEY"
JIRA_SESSION_TASK=ABC-5 run "key from session task" 0 key; has "ABC-5"
run "url" 0 url abc-3;                             has "https://plane.example.com/acme/browse/ABC-3/"
run "url from a browse URL" 0 url https://plane.example.com/acme/browse/ABC-7/; has "/acme/browse/ABC-7/"

echo "== work items"
run "issue" 0 issue ABC-1
has "title=Export fails for item 1"; has "state=Todo"; has "assignees=Me"; has "The export fails."; has "- CSV & XLSX"
run "issue not found" 1 issue ABC-404;             has "not found"
FAKE_PLANE_FAIL=429 run "retry after 429" 0 issue ABC-2; has "title=Export fails for item 2"
rm -f "$FAKE_PLANE_DIR/failed"
FAKE_PLANE_FAIL=429:3 run "retry after 429 three times" 0 issue ABC-2; has "title=Export fails for item 2"
rm -f "$FAKE_PLANE_DIR/failed"
FAKE_PLANE_FAIL=500:2 run "500 twice" 1 issue ABC-2; has "HTTP 500"
rm -f "$FAKE_PLANE_DIR/failed"
PLANE_API_KEY=" " run "empty token" 1 issue ABC-1; has "HTTP 401"
requests;                                          hasnt "$TOKEN"
: > "$FAKE_PLANE_DIR/requests.log"
run "states" 0 states ABC-1;                       has "In Progress"
run "move start" 0 move ABC-1 start;               has "ABC-1: Todo → In Progress"
run "move start again" 0 move ABC-1 start;         has "already in In Progress"
run "move close (prefix match)" 0 move ABC-1 close; has "In Progress → Deployed for testing"
run "move nowhere" 3 move ABC-1 nowhere;           has "Available"
run "mine" 0 mine;                                 has "ABC-1"; has "ABC-2"; has "Deployed for testing"

echo "== worklogs"
run "figures" 0 figures ABC-1;                     has "rounded_seconds=5400"; has "time_spent=1h 30m"
run "log-work bad seconds" 1 log-work ABC-1 1h 2026-09-07
run "log-work bad started" 1 log-work ABC-1 60 "next week"
run "log-work" 0 log-work ABC-1 4500 "2026-09-07T09:00:00.000+0000" "Fix, tests."
has "comment_id=ci1-1"; has "existing=0"; has "recorded as logged"
run "log-work again" 0 log-work ABC-1 4500 "2026-09-07T09:00:00.000+0000" "Fix, tests."
has "comment_id=ci1-1"; has "existing=1"; has "ledger=already recorded"
run "logged" 0 logged;                             has "ci1-1"
run "figures after" 0 figures ABC-1;               has "logged_seconds=4500"; has "time_spent=15m"
run "comments" 0 comments ABC-1;                   has "worklog 1h 15m started 2026-09-07 09:00 · Fix, tests."
run "worklogs" 0 worklogs ABC-1;                   has "$(printf 'ABC-1\tci1-1\t1788771600\t4500\t1\tclaude-timer\tFix, tests.')"
run "worklogs, other day" 0 worklogs ABC-1 2026-09-08; hasnt "ci1-1"
run "worklogs, from day" 0 worklogs ABC-1 2026-09-07; has "ci1-1"
run_in "⏱ 30m · started 2026-09-08 14:00 · typed by hand" "hand worklog" 0 comment ABC-1; has "comment_id=ci1-2"
run "worklogs, hand" 0 worklogs ABC-1;             has "$(printf '1800\t1\thand\ttyped by hand')"
run "worklog-days" 0 worklog-days 2026-09-07 2026-09-08
has "$(printf '2026-09-07\tABC-1\t4500\t1')"; has "$(printf '2026-09-08\tABC-1\t1800\t1')"
rm -f "$FAKE_PLANE_DIR/failed"
FAKE_PLANE_FAIL=429:8 run "worklog-days, rate limit" 1 worklog-days 2026-09-07 2026-09-08; has "RATE_LIMIT_EXCEEDED"
rm -f "$FAKE_PLANE_DIR/failed"
run "ledger-check" 0 ledger-check ABC-1;           has "$(printf 'ABC-1\tci1-1\t4500\t4500\tok')"
run "day" 0 day 2026-09-07;                        has "ABC-1"; hasnt "XYZ-9"
run "month" 0 month 09-2026;                       has "billable_seconds=6300"; hasnt "XYZ-9"
run "forget" 0 forget ci1-1;                       has "Removed 1 ledger row(s)"
run "ledger-check after forget" 0 ledger-check;    has "No ledger rows."
run "log-work after forget" 0 log-work ABC-1 4500 1788771600 "Fix, tests."
has "existing=1"; has "recorded as logged"

echo "== comments and edits"
run_in "$(printf '**Fix**\n\n- one `a<b`\n- two *it*\nlast & line')" "comment markdown" 0 comment ABC-2
requests
has '<p><strong>Fix</strong></p><ul><li><p>one <code>a&lt;b</code></p></li><li><p>two <em>it</em></p></li></ul><p>last &amp; line</p>'
run "comment, empty" 1 comment ABC-2;              has "Empty comment"
run "create" 0 create ABC --title "New item";      has "key=ABC-3"
requests;                                          has 'POST /api/v1/workspaces/acme/projects/p1/work-items/ auth=ok {"name":"New item"}'
run_in "Body" "create with description" 0 create ABC --title "Other"; has "key=ABC-3"
requests;                                          has '{"name":"Other","description_html":"<p>Body</p>"}'
run "update, nothing" 1 update ABC-2
run "update title" 0 update ABC-2 --title "Renamed"; has "ABC-2 updated (name)"
run "update assign-me, assigned" 0 update ABC-2 --assign-me; has "already assigned to me"

echo "== token"
requests
hasnt "$TOKEN"; hasnt "auth=missing "

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
