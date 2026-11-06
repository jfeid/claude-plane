#!/usr/bin/env bash
# Helper for the plane-worklog plugin (/plane): Plane REST API calls and local figures.
#
# Plane has no worklogs in the API this uses, so a worklog is a comment on the work item:
#   ⏱ 1h 15m · started 2026-10-05 09:36 · note
# posted with external_source=claude-timer and a deterministic external_id, so a repeated
# post returns 409 with the existing comment id instead of creating a duplicate.
#
# Setup:
#   plane.sh init BASE_URL [TIMEZONE]  write the config file (BASE_URL: https://app.plane.so
#                                      or your self-hosted Plane address)
#   plane.sh add-workspace SLUG [PREFIX...]
#                                      add a workspace with its projects (all, or the given
#                                      project identifiers) to the config
#   plane.sh check                     token, user and project access in every workspace
#   plane.sh config                    settings (with defaults) and the config file, never the token
# Local figures (timer log and ledger, Plane keys only; see lib/figures.sh):
#   plane.sh key|session-name|figures|parse-time|logged|context|day|month|base-branch ...
#   plane.sh mark-logged KEY SECONDS [COMMENT_ID] [NOTE] [STARTED]
# Work items:
#   plane.sh issue [KEY]               work item fields (key=value) and description text
#   plane.sh comments [KEY]            comments, oldest first; worklogs folded to one line
#   plane.sh worklogs [KEY] [FROM [TO]]
#                                      parsed worklog comments (TSV): key, comment_id,
#                                      started_epoch, seconds, mine, source, note
#   plane.sh worklog-days FROM TO [--scan]
#                                      my worklog seconds per day per key (TSV: date, key,
#                                      seconds, count) for keys in the timer logs or ledger
#                                      of that period; --scan: every work item instead
#   plane.sh log-work [KEY] SECONDS STARTED [NOTE]
#                                      post a worklog comment and record it in the ledger
#   plane.sh comment [KEY] [--html]    post a comment (markdown from stdin, or HTML)
#   plane.sh states [KEY]              project states (TSV: id, name, group)
#   plane.sh move [KEY] start|close|done|<state name>
#                                      change state; start/close/done use the config's lists
#   plane.sh ledger-check [KEY]        ledger rows vs Plane comments (TSV: key, comment_id,
#                                      ledger_seconds, plane_seconds, ok|changed|missing)
#   plane.sh forget COMMENT_ID         drop the ledger row(s) of a deleted or changed worklog
#   plane.sh mine                      open work items assigned to me
#   plane.sh url [KEY]                 browse URL
#   plane.sh get PATH                  raw GET under /api/v1 (JSON), for inspection
# Editing work items (markdown from stdin, as in comment; --html for raw HTML):
#   plane.sh update KEY [--title T] [--description] [--html] [--assign-me]
#                                      change the title, replace the description, add me
#                                      to the assignees
#   plane.sh create PREFIX --title T [--parent KEY] [--module NAME] [--state NAME]
#                  [--priority none|low|medium|high|urgent] [--html]
#                                      new work item, description from stdin; prints key=
#   plane.sh modules PREFIX            modules (TSV: id, name)
#   plane.sh add-state PREFIX NAME GROUP [COLOR] [SEQUENCE]
#                                      add a project state (skipped if the name exists),
#                                      e.g. add-state ABC Deployed started
#   plane.sh add-module PREFIX NAME [STATUS]
#                                      add a module (skipped if the name exists), description
#                                      from stdin (plain text); STATUS defaults to planned
#   plane.sh relations KEY             relations of a work item (TSV: type, key)
#   plane.sh relate KEY TYPE OTHER...  add relations, e.g. relate ABC-10 blocked_by ABC-56
#   plane.sh links KEY                 links of a work item (TSV: id, title, url)
#   plane.sh link KEY URL [TITLE]      add a link (skipped if the URL is already there)
#
# Config : $PLANE_HOME/config.json (PLANE_HOME defaults to ~/.claude/plane): baseUrl, apiUrl,
#          timezone, languages, baseBranch, transitions, workspaces.<slug>.projects
#          (PREFIX -> project id); a key's prefix picks its workspace
# Token  : workspace or top-level tokenFile from the config, else PLANE_API_KEY, else
#          $PLANE_HOME/token; read only here, sent to Plane on stdin of curl, never printed
# Ledger : $PLANE_HOME/logs/<project>.tsv   key, seconds, comment_id, epoch, timestamp,
#          note, started_epoch
# Timer  : the worklog-timer plugin's timer.sh and its logs, only read here

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FIGURES="$HERE/../lib/figures.sh"
ROOT="${PLANE_HOME:-$HOME/.claude/plane}"
CONFIG="$ROOT/config.json"
TIMER_BIN="${TIMER_BIN:-$(command -v timer.sh 2>/dev/null)}"
SOURCE="claude-timer"

die() { echo "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "plane.sh needs jq (https://jqlang.org/download/)."
# jq on Windows writes CRLF line ends; drop the CR so values compare.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) jq() { command jq "$@" | tr -d '\r'; } ;;
esac

# ---- dates: GNU date (Linux, Git Bash, gdate on macOS) or BSD date (macOS) ---

if date -d @0 +%s >/dev/null 2>&1; then GDATE=date
elif command -v gdate >/dev/null 2>&1; then GDATE=gdate
else GDATE=""; fi

gnu_date() { if [ "$GDATE" = gdate ]; then gdate "$@"; else date "$@"; fi; }

# YYYY-MM-DD for a date spec; BSD date knows today, yesterday, tomorrow and YYYY-MM-DD.
day_of() {
    local spec="${1:-today}"
    if [ -n "$GDATE" ]; then gnu_date -d "$spec" +%Y-%m-%d 2>/dev/null; return; fi
    case "$spec" in
        today)     date +%Y-%m-%d ;;
        yesterday) date -v-1d +%Y-%m-%d ;;
        tomorrow)  date -v+1d +%Y-%m-%d ;;
        [0-9][0-9][0-9][0-9]-[0-9]*-[0-9]*) date -j -f %Y-%m-%d "$spec" +%Y-%m-%d 2>/dev/null ;;
        *) echo "macOS date reads today, yesterday, tomorrow or YYYY-MM-DD;" \
                "install coreutils (brew install coreutils) for '$spec'." >&2; return 1 ;;
    esac
}
midnight() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1 00:00:00" +%s
    else date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s; fi
}
next_day() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1 + 1 day" +%Y-%m-%d
    else date -j -v+1d -f %Y-%m-%d "$1" +%Y-%m-%d; fi
}
fmt_epoch() { if [ -n "$GDATE" ]; then gnu_date -d "@$1" "+$2"; else date -r "$1" "+$2"; fi; }

# Epoch of an epoch, an ISO 8601 time (2026-09-07T11:24:00.000+0300, Z, +03:00),
# "YYYY-MM-DD HH:MM[:SS]" or "YYYY-MM-DD" (local midnight).
to_epoch() {
    local s="$1" base tz
    [[ "$s" =~ ^[0-9]+$ ]] && { echo "$s"; return 0; }
    s=$(printf '%s' "$s" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/^([0-9-]{10}) /\1T/')
    if [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then midnight "$s"; return; fi
    [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{1,2}:[0-9]{2})(:[0-9]{2})?([+-][0-9]{4})?$ ]] || return 1
    base="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}${BASH_REMATCH[3]:-:00}"
    tz="${BASH_REMATCH[4]}"
    if [ -n "$GDATE" ]; then gnu_date -d "$base$tz" +%s 2>/dev/null
    elif [ -n "$tz" ]; then date -j -f '%Y-%m-%d %H:%M:%S%z' "$base$tz" +%s 2>/dev/null
    else date -j -f '%Y-%m-%d %H:%M:%S' "$base" +%s 2>/dev/null; fi
}

# Start of FROM and end (exclusive) of TO, as epochs: sets A and Z.
period() {
    local d
    d=$(day_of "$1") && [ -n "$d" ] || die "Cannot understand date '$1'."
    A=$(midnight "$d")
    d=$(day_of "$2") && [ -n "$d" ] || die "Cannot understand date '$2'."
    Z=$(midnight "$(next_day "$d")")
}

fmt() {
    awk -v s="$1" 'BEGIN{ if (s<0) s=0; h=int(s/3600); m=int((s%3600)/60);
        if (h>0 && m>0) printf "%dh %dm", h, m; else if (h>0) printf "%dh", h; else printf "%dm", m }'
}

# ---- config -------------------------------------------------------------------

cfg() { jq -r "$1"' // empty | if type == "array" then join(" ") else tostring end' "$CONFIG"; }

# Workspaces: .workspaces.<slug> = {projects: {PREFIX: id}, [prefixes], [transitions],
# [tokenFile]}. The prefixes of a workspace are its project keys plus .prefixes. A key's
# prefix selects its workspace, so a prefix belongs to one workspace only. The older
# single-workspace form (.workspace, .projects, .prefixes at the top) is still read.
JQ_WS='def wsmap: if .workspaces then .workspaces
    else {(.workspace // ""): {projects: (.projects // {}), prefixes: (.prefixes // [])}} end;'

BASE=""; API_ROOT=""; API=""; PREFIX_MAP=""; PREFIXES=""; WORKSPACES=""; WS=""; TOKEN_FILE=""
load_config() {
    [ -r "$CONFIG" ] || die "Missing $CONFIG. Create it with: plane.sh init BASE_URL"
    jq -e 'type == "object"' "$CONFIG" >/dev/null 2>&1 || die "$CONFIG is not a JSON object."
    BASE=$(cfg .baseUrl); BASE="${BASE%/}"
    API_ROOT=$(cfg .apiUrl); API_ROOT="${API_ROOT%/}"; API_ROOT="${API_ROOT:-$BASE}"
    [ -n "$BASE" ] || die "$CONFIG has no baseUrl."
    API="$API_ROOT/api/v1"
    local tz dup
    tz=$(cfg .timezone)
    [ -n "$tz" ] && export TZ="$tz"
    # "PREFIX<TAB>workspace" lines
    PREFIX_MAP=$(jq -r "$JQ_WS"' wsmap | to_entries[] | .key as $w
        | [((.value.projects // {}) | keys[]), (.value.prefixes // [])[]] | map(ascii_upcase) | unique[]
        | "\(.)\t\($w)"' "$CONFIG")
    dup=$(printf '%s\n' "$PREFIX_MAP" | cut -f1 | awk 'NF' | sort | uniq -d | head -1)
    [ -z "$dup" ] || die "$CONFIG: prefix $dup is in more than one workspace; a prefix belongs to one workspace."
    PREFIXES=$(printf '%s\n' "$PREFIX_MAP" | cut -f1 | awk 'NF' | sort | tr '\n' ' ' | sed 's/ $//')
    WORKSPACES=$(jq -r "$JQ_WS"' wsmap | keys[] | select(. != "")' "$CONFIG")
    if [ "$(printf '%s\n' "$WORKSPACES" | awk 'NF' | wc -l | tr -d ' ')" = 1 ]; then set_ws "$WORKSPACES"; fi
}
need_prefixes() {
    [ -n "$PREFIXES" ] || die "No projects in $CONFIG yet. Add a workspace with: plane.sh add-workspace SLUG"
}

# Workspace setting, else the top-level one: ws_cfg .tokenFile
ws_cfg() { jq -r --arg w "$WS" "$JQ_WS"' (wsmap[$w]'"$1"') // '"$1"' // empty' "$CONFIG"; }
set_ws() {
    WS="$1"
    TOKEN_FILE=$(ws_cfg .tokenFile)
    case "$TOKEN_FILE" in "~/"*) TOKEN_FILE="$HOME/${TOKEN_FILE#\~/}" ;; esac
}
ws_of() { printf '%s\n' "$PREFIX_MAP" | awk -F'\t' -v p="$1" '$1==p {print $2; exit}'; }
# Point WS at the workspace owning KEY or PREFIX.
use_ws() {
    local p w
    p=$(printf '%s' "${1%%-*}" | tr '[:lower:]' '[:upper:]')
    w=$(ws_of "$p")
    [ -n "$w" ] || die "Prefix $p is not in any workspace of $CONFIG."
    set_ws "$w"
}
# Relations and parents stay inside one workspace.
same_ws() {
    local w; w=$(ws_of "${1%%-*}")
    [ "$w" = "$WS" ] || die "$1 is in workspace ${w:-?}, not $WS; Plane links work items within one workspace only."
}

# Where the token comes from, without reading it.
token_source() {
    if [ -n "$TOKEN_FILE" ]; then echo "$TOKEN_FILE"
    elif [ -n "${PLANE_API_KEY:-}" ]; then echo "PLANE_API_KEY"
    else echo "$ROOT/token"; fi
}
token() {
    local src; src=$(token_source)
    if [ "$src" = PLANE_API_KEY ]; then printf '%s' "$PLANE_API_KEY" | tr -d '[:space:]'; return; fi
    [ -r "$src" ] || die "No Plane API token: create one in Plane (profile settings, Personal Access Tokens) and save it in $ROOT/token, or set PLANE_API_KEY."
    tr -d '[:space:]' < "$src"
}

# ---- local figures --------------------------------------------------------------

local_figures() {
    JIRA_HOME="$ROOT" KEY_PREFIX_INCLUDE="$PREFIXES" KEY_TRACKER=Plane KEY_COMMAND=/plane \
        TIMER_BIN="$TIMER_BIN" bash "$FIGURES" "$@"
}
resolve_key() { local_figures key "${1:-}"; }

# The timer's project, as figures.sh and timer.sh see it.
project_slug() {
    if [ -n "${TIMER_PROJECT:-}" ]; then echo "$TIMER_PROJECT"; return; fi
    local w top
    if [ -n "$TIMER_BIN" ] && [ -x "$TIMER_BIN" ]; then
        w=$("$TIMER_BIN" where 2>/dev/null)
        [ -n "$w" ] && { basename "$w" .tsv; return; }
    fi
    top=$(git rev-parse --show-toplevel 2>/dev/null); [ -z "$top" ] && top="$(pwd)"
    printf '%s' "$(basename "$top")" | tr -c 'A-Za-z0-9._-' '-'
}

# ---- HTTP -----------------------------------------------------------------------

# api METHOD PATH [JSON]: sets BODY and HTTP in the calling shell. Retries once on
# 429/5xx. The token goes to curl as a config file on stdin, so it is not in argv.
HTTP=000; BODY=""
api() {
    local method="$1" path="$2" data="${3:-}" out try url tok
    tok=$(token) || exit 1
    case "$path" in /api/*) url="$API_ROOT$path" ;; *) url="$API$path" ;; esac
    for try in 1 2; do
        out=$(printf 'header = "X-API-Key: %s"\n' "$tok" |
            curl -sS --max-time 30 -K - -X "$method" -w '\n%{http_code}' \
                -H 'Content-Type: application/json' ${data:+--data-binary "$data"} "$url") || out=$'\n000'
        HTTP="${out##*$'\n'}"
        BODY="${out%$'\n'*}"
        case "$HTTP" in
            429|5??|000) [ "$try" = 1 ] || break
                         sleep "${PLANE_RETRY_WAIT:-$([ "$HTTP" = 429 ] && echo 20 || echo 3)}" ;;
            *) break ;;
        esac
    done
}

api_error() { printf '%s' "$BODY" | jq -c '.error // .detail // .' 2>/dev/null | cut -c1-300; }

# api_ok METHOD PATH [JSON]: like api, but dies on any status outside 2xx.
api_ok() {
    api "$@"
    case "$HTTP" in
        2??) ;;
        401|403) die "Plane API $1 $2: HTTP $HTTP (check the token and access to workspace $WS) $(api_error)" ;;
        *) die "Plane API $1 $2 failed: HTTP $HTTP $(api_error)" ;;
    esac
}

# Every page of a cursor-paginated list, results concatenated as one JSON array.
api_all() {
    local path="$1" sep cursor="" body all="[]"
    case "$path" in *\?*) sep='&' ;; *) sep='?' ;; esac
    while :; do
        api_ok GET "$path${sep}per_page=100${cursor:+&cursor=$cursor}"; body="$BODY"
        all=$(jq -c --argjson a "$all" '$a + (if type == "array" then . else (.results // []) end)' <<< "$body")
        [ "$(jq -r 'if type == "object" then (.next_page_results // false) else false end' <<< "$body")" = "true" ] || break
        cursor=$(jq -r '.next_cursor' <<< "$body")
    done
    printf '%s' "$all"
}

me_id() { [ -n "${ME_ID:-}" ] || { api_ok GET /users/me/; ME_ID=$(jq -r .id <<< "$BODY"); }; echo "$ME_ID"; }

# Work item JSON for KEY (state and project expanded); the last one is cached.
ISSUE_KEY=""; ISSUE_BODY=""
issue_json() {
    local key="$1"
    if [ "$ISSUE_KEY" != "$key" ]; then
        api GET "/workspaces/$WS/work-items/$key/?expand=state,project"
        case "$HTTP" in
            2??) ;;
            404) die "$key not found in Plane workspace $WS." ;;
            *) die "Plane API GET $key failed: HTTP $HTTP $(api_error)" ;;
        esac
        ISSUE_KEY="$key"; ISSUE_BODY="$BODY"
    fi
    printf '%s' "$ISSUE_BODY"
}
# "<work item id>\t<project id>"
issue_ids() { issue_json "$1" | jq -r '[.id, (.project | if type == "object" then .id else . end)] | @tsv'; }

# Workspace member id -> display name, as a JSON object.
member_map() {
    api GET "/workspaces/$WS/members/"
    case "$HTTP" in
        2??) jq -c '(if type == "array" then . else (.results // []) end)
                | map({key: (.id // .member // ""), value: (.display_name // .first_name // .email // "")}) | from_entries' <<< "$BODY" 2>/dev/null || echo '{}' ;;
        *) echo '{}' ;;
    esac
}

project_id_for() {
    local ident id
    ident=$(printf '%s' "${1%%-*}" | tr '[:lower:]' '[:upper:]')
    id=$(jq -r --arg w "$WS" --arg i "$ident" "$JQ_WS"' wsmap[$w].projects // {} | to_entries[]
        | select(.key | ascii_upcase == $i) | .value' "$CONFIG" | head -1)
    [ -n "$id" ] || id=$(api_all "/workspaces/$WS/projects/" | jq -r --arg i "$ident" '.[] | select(.identifier == $i) | .id')
    [ -n "$id" ] || die "Project $ident not found in workspace $WS."
    echo "$id"
}

# HTML to plain text (enough for Plane's rich text: paragraphs, lists, breaks).
JQ_TEXT='def text: gsub("</p>\\s*</li>"; "</li>") | gsub("<br */?>"; "\n") | gsub("</(p|li|h[1-6]|blockquote|pre)>"; "\n") | gsub("<li[^>]*>"; "- ")
    | gsub("<[^>]+>"; "") | gsub("&nbsp;"; " ") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"")
    | gsub("&#39;|&apos;"; "'"'"'") | gsub("&amp;"; "&") | gsub("\n{3,}"; "\n\n") | sub("\\s+$"; "");'

# Worklog pattern on the comment text: ⏱ 1h 15m · started YYYY-MM-DD HH:MM · note
JQ_WORKLOG='def worklog: text as $t
    | ($t | capture("^\\s*⏱\\s*(?:(?<h>\\d+)\\s*h)?\\s*(?:(?<m>\\d+)\\s*m(?:in)?)?\\s*·\\s*started\\s+(?<d>\\d{4}-\\d{2}-\\d{2})\\s+(?<t>\\d{1,2}:\\d{2})\\s*(?:·\\s*(?<note>[\\s\\S]*))?$")? // null)
    | if . == null then null else
        {seconds: (((.h // "0") | tonumber) * 3600 + ((.m // "0") | tonumber) * 60),
         started: (.d + " " + .t), note: ((.note // "") | gsub("\\s+"; " "))} end;'

JQ_DUR='def dur: (. / 3600 | floor) as $h | ((. % 3600) / 60 | floor) as $m
    | if $h > 0 and $m > 0 then "\($h)h \($m)m" elif $h > 0 then "\($h)h" else "\($m)m" end;'

# Minimal markdown to HTML: paragraphs, "- " bullets, **bold**, *italic*, `code`.
JQ_MD='def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
def inline: esc
    | gsub("\\*\\*(?<x>.+?)\\*\\*"; "<strong>\(.x)</strong>")
    | gsub("(?<![\\w*])\\*(?=\\S)(?<x>[^*]+?)(?<=\\S)\\*(?![\\w*])"; "<em>\(.x)</em>")
    | gsub("`(?<x>[^`]+)`"; "<code>\(.x)</code>");
def flush:
    (if (.para | length) > 0 then .out += "<p>" + (.para | map(inline) | join("<br>")) + "</p>" | .para = [] else . end)
    | (if (.items | length) > 0 then .out += "<ul>" + (.items | map("<li><p>" + inline + "</p></li>") | join("")) + "</ul>" | .items = [] else . end);
reduce (gsub("\r"; "") | split("\n")[] | sub("\\s+$"; "")) as $l ({out: "", para: [], items: []};
    if ($l | test("^\\s*$")) then flush
    elif ($l | test("^\\s*[-*]\\s+")) then (if (.para | length) > 0 then flush else . end) | .items += [$l | sub("^\\s*[-*]\\s+"; "")]
    else (if (.items | length) > 0 then flush else . end) | .para += [$l | sub("^\\s+"; "")] end)
| flush | .out'
md_to_html() { jq -Rrs "$JQ_MD"; }

# Parsed worklog comments for KEY as TSV: key, comment_id, started_epoch, seconds, mine, source, note
worklog_rows() {
    local key="$1" iid pid me k id started secs mine src note
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    me=$(me_id) || exit 1
    api_all "/workspaces/$WS/projects/$pid/work-items/$iid/comments/" | jq -r --arg k "$key" --arg me "$me" --arg src "$SOURCE" \
        "$JQ_TEXT $JQ_WORKLOG"'
        .[] | select(.deleted_at == null) | . as $c | (.comment_html // "" | worklog) as $w | select($w != null)
        | [$k, $c.id, $w.started, $w.seconds, (if $c.created_by == $me then 1 else 0 end),
           (if $c.external_source == $src then $src else "hand" end), $w.note] | @tsv' |
    while IFS=$'\t' read -r k id started secs mine src note; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$k" "$id" "$(to_epoch "$started")" "$secs" "$mine" "$src" "$note"
    done
}

# ---- commands -------------------------------------------------------------------

cmd_init() {
    local url="${1:-}" tz="${2:-}" api_url=""
    [[ "$url" =~ ^https?://[A-Za-z0-9.:-]+(/[A-Za-z0-9._~/-]*)?$ ]] ||
        die "Usage: plane.sh init BASE_URL [TIMEZONE] (BASE_URL like https://app.plane.so or https://plane.example.com)"
    url="${url%/}"
    case "$url" in https://app.plane.so) api_url="https://api.plane.so" ;; esac
    [ -e "$CONFIG" ] && die "$CONFIG exists already; edit it instead."
    mkdir -p "$ROOT" 2>/dev/null || die "plane: cannot write $ROOT"
    jq -n --arg b "$url" --arg a "$api_url" --arg tz "$tz" '{
        baseUrl: $b, apiUrl: $a, timezone: $tz,
        commentLanguage: "English", worklogLanguage: "English", baseBranch: "",
        transitions: {start: ["In Progress"], close: ["Deployed", "Ready for testing", "In Review"], done: ["Done"]},
        workspaces: {}}' > "$CONFIG" || die "plane: cannot write $CONFIG"
    echo "Wrote $CONFIG"
}

cmd_add_workspace() {
    local slug="${1:-}" projects sel tmp; shift || true
    [[ "$slug" =~ ^[A-Za-z0-9_-]+$ ]] || die "Usage: plane.sh add-workspace SLUG [PREFIX...] (SLUG is the first part of the path in Plane's URLs)"
    set_ws "$slug"
    projects=$(api_all "/workspaces/$slug/projects/") || exit 1
    sel=$(printf '%s\n' "$@" | tr '[:lower:]' '[:upper:]' | jq -R . | jq -sc 'map(select(. != ""))')
    projects=$(jq -c --argjson sel "$sel" '[.[] | select(($sel | length) == 0 or (.identifier as $i | $sel | index($i)))]
        | map({key: .identifier, value: .id}) | from_entries' <<< "$projects")
    [ "$projects" != "{}" ] || die "No matching projects in workspace $slug."
    tmp="$CONFIG.tmp.$$"
    jq --arg w "$slug" --argjson p "$projects" '.workspaces[$w].projects = ((.workspaces[$w].projects // {}) + $p)' "$CONFIG" > "$tmp" &&
        mv "$tmp" "$CONFIG" || { rm -f "$tmp"; die "plane: cannot write $CONFIG"; }
    load_config
    jq -r 'to_entries[] | "project=\(.key) \(.value)"' <<< "$projects"
    echo "workspace=$slug added to $CONFIG"
}

cmd_check() {
    local w p projects
    need_prefixes
    for w in $WORKSPACES; do
        set_ws "$w"
        api_ok GET /users/me/
        echo "workspace=$w user=$(jq -r '.display_name // .email' <<< "$BODY") token=$(token_source)"
        projects=$(api_all "/workspaces/$w/projects/") || exit 1
        jq -r --arg w "$w" '.[] | "project=\($w)/\(.identifier) \(.id) \(.name)"' <<< "$projects"
        for p in $PREFIXES; do
            [ "$(ws_of "$p")" = "$w" ] || continue
            jq -e --arg p "$p" 'any(.[]; .identifier == $p)' <<< "$projects" >/dev/null \
                || echo "MISSING prefix $p: no project with that identifier in $w"
        done
    done
    echo "prefixes=$(for p in $PREFIXES; do printf '%s:%s ' "$p" "$(ws_of "$p")"; done | sed 's/ $//')"
}

cmd_config() {
    local w cl wl
    cl=$(cfg .commentLanguage); wl=$(cfg .worklogLanguage)
    echo "path=$CONFIG"
    echo "base_url=$BASE"
    echo "api_url=$API_ROOT"
    echo "timezone=$(cfg .timezone)"
    echo "comment_language=${cl:-English}"
    echo "worklog_language=${wl:-English}"
    echo "base_branch=$(local_figures base-branch 2>/dev/null)"
    echo "prefixes=$PREFIXES"
    for w in $WORKSPACES; do
        set_ws "$w"
        local src; src=$(token_source)
        if [ "$src" = PLANE_API_KEY ]; then echo "workspace=$w token=PLANE_API_KEY"
        else echo "workspace=$w token=$src ($([ -r "$src" ] && echo present || echo MISSING))"; fi
    done
    echo "ledger=$ROOT/logs/$(project_slug).tsv"
    echo "timer=${TIMER_BIN:-missing}"
    echo "--- $CONFIG"
    jq 'del(.token)' "$CONFIG"
}

cmd_issue() {
    local key="$1" j members
    j=$(issue_json "$key") || exit 1
    members=$(member_map)
    jq -r --arg k "$key" --arg url "$(cmd_url "$key")" --argjson mem "$members" "$JQ_TEXT"'
        "key=\($k)", "id=\(.id)", "title=\(.name)",
        "state=\(.state.name // .state)", "state_group=\(.state.group // "")",
        "priority=\(.priority)", "assignees=\([.assignees[]? | if type == "object" then .id else . end | $mem[.] // .] | join(", "))",
        "created=\(.created_at[0:16] | sub("T"; " "))", "updated=\(.updated_at[0:16] | sub("T"; " "))",
        "url=\($url)", "--- description", ((.description_html // "") | text)' <<< "$j"
}

cmd_comments() {
    local key="$1" iid pid members
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    members=$(member_map)
    api_all "/workspaces/$WS/projects/$pid/work-items/$iid/comments/" | jq -r --argjson mem "$members" "$JQ_TEXT $JQ_WORKLOG $JQ_DUR"'
        sort_by(.created_at) | .[] | select(.deleted_at == null)
        | (.comment_html // "" | worklog) as $w
        | "[\(.created_at[0:16] | sub("T"; " "))] \($mem[.created_by] // .created_by)"
          + (if $w then " · worklog \($w.seconds | dur) started \($w.started) · \($w.note)"
             else ":\n" + (.comment_html // "" | text) + "\n" end)'
}

cmd_worklogs() {
    local key="$1" from="${2:-}" to="${3:-}" A=0 Z=99999999999
    if [ -n "$from" ]; then
        period "$from" "${to:-$from}"
        [ -n "$to" ] || Z=99999999999
    fi
    worklog_rows "$key" | awk -F'\t' -v a="$A" -v z="$Z" '$3>=a && $3<z'
}

# Keys of Plane seen in the timer logs or the ledger within [A, Z).
period_keys() {
    local a="$1" z="$2" f troot k
    troot="${TIMER_HOME:-$HOME/.claude/timer}"
    {
        for f in "$troot"/logs/*.tsv; do [ -s "$f" ] && awk -F'\t' -v a="$a" -v z="$z" '$3>=a && $3<z {print $1}' "$f"; done
        for f in "$ROOT"/logs/*.tsv; do [ -s "$f" ] && awk -F'\t' -v a="$a" -v z="$z" '{e=($7!="" ? $7 : $4)} e>=a && e<z {print $1}' "$f"; done
    } | sort -u | while IFS= read -r k; do
        [[ " $PREFIXES " == *" ${k%%-*} "* ]] && echo "$k"
    done
}

cmd_worklog_days() {
    local from="$1" to="$2" scan="${3:-}" A Z keys k p pid id e s mine src note
    period "$from" "$to"
    if [ "$scan" = "--scan" ]; then
        keys=$(for p in $PREFIXES; do
            use_ws "$p"
            pid=$(project_id_for "$p") || exit 1
            api_all "/workspaces/$WS/projects/$pid/work-items/" | jq -r --arg p "$p" '.[] | "\($p)-\(.sequence_id)"'
        done) || exit 1
    else
        keys=$(period_keys "$A" "$Z")
    fi
    for k in $keys; do
        use_ws "$k"
        worklog_rows "$k" | awk -F'\t' -v a="$A" -v z="$Z" '$5==1 && $3>=a && $3<z'
    done | while IFS=$'\t' read -r k id e s mine src note; do
        printf '%s\t%s\t%s\n' "$(fmt_epoch "$e" %Y-%m-%d)" "$k" "$s"
    done | awk -F'\t' -v OFS='\t' '{ s[$1 OFS $2]+=$3; n[$1 OFS $2]++ } END { for (x in s) print x, s[x], n[x] }' | sort
}

cmd_log_work() {
    local key="$1" secs="$2" started="$3" note="$4" iid pid epoch stamp html body resp id existing=0 ext
    [[ "$secs" =~ ^[1-9][0-9]*$ ]] || die "SECONDS must be a positive integer (got '$secs')."
    epoch=$(to_epoch "$started") && [ -n "$epoch" ] || die "Cannot parse STARTED '$started' (ISO 8601, 'YYYY-MM-DD HH:MM' or epoch)."
    stamp=$(fmt_epoch "$epoch" '%Y-%m-%d %H:%M')
    note=$(printf '%s' "$note" | tr '\t\n\r' '   ')
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    ext="$(project_slug):$key:$epoch:$secs"
    html=$(jq -rn --arg t "$(fmt "$secs")" --arg s "$stamp" --arg n "$note" \
        '"<p>⏱ <strong>\($t)</strong> · started \($s)" + (if $n != "" then " · " + ($n | @html) else "" end) + "</p>"')
    body=$(jq -cn --arg h "$html" --arg src "$SOURCE" --arg ext "$ext" '{comment_html: $h, external_source: $src, external_id: $ext}')
    api POST "/workspaces/$WS/projects/$pid/work-items/$iid/comments/" "$body"; resp="$BODY"
    case "$HTTP" in
        2??) id=$(jq -r .id <<< "$resp") ;;
        409) id=$(jq -r '.id // empty' <<< "$resp"); existing=1
             [ -n "$id" ] || die "Worklog comment exists already (HTTP 409) but Plane gave no id: $(api_error)" ;;
        *)   die "Worklog comment failed: HTTP $HTTP $(api_error)" ;;
    esac
    echo "comment_id=$id"
    echo "existing=$existing"
    if local_figures logged "$key" 2>/dev/null | grep -qF -- "$id"; then
        echo "ledger=already recorded"
    else
        local_figures mark-logged "$key" "$secs" "$id" "$note" "$epoch"
    fi
}

# Ledger rows of KEY (all keys of this project's ledger when empty) compared with Plane:
# TSV: key, comment_id, ledger_seconds, plane_seconds, status (ok | changed | missing)
cmd_ledger_check() {
    local only="${1:-}" ledger k rows id secs ps
    ledger="$ROOT/logs/$(project_slug).tsv"
    [ -s "$ledger" ] || { echo "No ledger rows."; return; }
    for k in $(awk -F'\t' -v k="$only" 'k=="" || $1==k {print $1}' "$ledger" | sort -u); do
        if [ -z "$(ws_of "${k%%-*}")" ]; then echo "$k: prefix not in $CONFIG, skipped" >&2; continue; fi
        use_ws "$k"
        rows=$(worklog_rows "$k") || exit 1
        while IFS=$'\t' read -r id secs; do
            ps=$(printf '%s\n' "$rows" | awk -F'\t' -v id="$id" '$2==id {print $4}')
            if [ -z "$ps" ]; then printf '%s\t%s\t%s\t-\tmissing\n' "$k" "$id" "$secs"
            elif [ "$ps" != "$secs" ]; then printf '%s\t%s\t%s\t%s\tchanged\n' "$k" "$id" "$secs" "$ps"
            else printf '%s\t%s\t%s\t%s\tok\n' "$k" "$id" "$secs" "$ps"; fi
        done < <(awk -F'\t' -v k="$k" '$1==k {print $3"\t"$2}' "$ledger")
    done
}

# Drop the ledger row(s) of COMMENT_ID (after the comment was deleted or changed in Plane).
cmd_forget() {
    local id="$1" ledger n
    ledger="$ROOT/logs/$(project_slug).tsv"
    [ -s "$ledger" ] || die "No ledger at $ledger."
    n=$(awk -F'\t' -v id="$id" '$3==id' "$ledger" | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] || die "No ledger row with comment id $id in $ledger."
    cp "$ledger" "$ledger.bak-$(date +%s)" || die "plane: cannot back up $ledger"
    awk -F'\t' -v id="$id" '$3!=id' "$ledger" > "$ledger.tmp" && mv "$ledger.tmp" "$ledger" || die "plane: cannot write $ledger"
    echo "Removed $n ledger row(s) for $id (backup next to $ledger)."
}

cmd_comment() {
    local key="$1" mode="${2:-}" iid pid input html
    input=$(cat)
    [ -n "$(printf '%s' "$input" | tr -d '[:space:]')" ] || die "Empty comment (pass it on stdin)."
    if [ "$mode" = "--html" ]; then html="$input"; else html=$(printf '%s' "$input" | md_to_html); fi
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    api_ok POST "/workspaces/$WS/projects/$pid/work-items/$iid/comments/" "$(jq -cn --arg h "$html" '{comment_html: $h}')"
    echo "comment_id=$(jq -r .id <<< "$BODY")"
}

cmd_states() {
    local key="$1" pid
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r _ pid <<< "$(issue_ids "$key")"
    [ -n "$pid" ] || exit 1
    api_all "/workspaces/$WS/projects/$pid/states/" | jq -r 'sort_by(.sequence) | .[] | [.id, .name, .group] | @tsv'
}

cmd_move() {
    local key="$1" target="$2" prefs states cur iid pid sid="" name=""
    case "$target" in
        start|close|done)
            prefs=$(jq -r --arg w "$WS" --arg t "$target" "$JQ_WS"'
                (wsmap[$w].transitions[$t]) // .transitions[$t] // [] | if type == "array" then .[] else . end' "$CONFIG")
            if [ -z "$prefs" ]; then
                case "$target" in
                    start) prefs="In Progress" ;;
                    close) prefs=$'Deployed\nReady for testing\nIn Review' ;;
                    done)  prefs="Done" ;;
                esac
            fi ;;
        *) prefs="$target" ;;
    esac
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    cur=$(issue_json "$key" | jq -r '.state.name // .state')
    states=$(cmd_states "$key") || exit 1
    # First preference equal to a state name (case-insensitive), else the first state
    # starting with the first preference ("Deployed" matches "Deployed for testing").
    IFS=$'\t' read -r sid name < <(printf '%s\n' "$states" | awk -F'\t' -v prefs="$prefs" '
        BEGIN { n=split(prefs, p, "\n") }
        { id[NR]=$1; nm[NR]=$2; rows=NR }
        END {
            for (i=1;i<=n;i++) for (r=1;r<=rows;r++) if (tolower(nm[r])==tolower(p[i])) { print id[r] "\t" nm[r]; exit }
            for (r=1;r<=rows;r++) if (index(tolower(nm[r]), tolower(p[1]))==1) { print id[r] "\t" nm[r]; exit }
        }')
    if [ -z "$sid" ]; then
        echo "No state matches '$(printf '%s' "$prefs" | tr '\n' '|' | sed 's/|/, /g')'. Available:" >&2
        printf '%s\n' "$states" | cut -f2,3 >&2
        exit 3
    fi
    if [ "$(printf '%s' "$cur" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" ]; then
        echo "$key already in $cur"; return
    fi
    api_ok PATCH "/workspaces/$WS/projects/$pid/work-items/$iid/" "$(jq -cn --arg s "$sid" '{state: $s}')"
    echo "$key: $cur → $name"
}

cmd_mine() {
    local me p pid
    need_prefixes
    for p in $PREFIXES; do
        use_ws "$p"
        me=$(me_id) || exit 1
        pid=$(project_id_for "$p") || exit 1
        api_all "/workspaces/$WS/projects/$pid/work-items/?expand=state" | jq -r --arg me "$me" --arg p "$p" '
            .[] | select([(.assignees // [])[] | if type == "object" then .id else . end] | index($me))
            | select(.state.group != "completed" and .state.group != "cancelled")
            | [.updated_at[0:10], "\($p)-\(.sequence_id)", .state.name, .name] | @tsv'
        ME_ID=""
    done | sort -r | awk -F'\t' '{ printf "%-10s %-12s %-14s %s\n", $1, $2, $3, substr($4,1,70) }'
}

cmd_url() { echo "$BASE/$WS/browse/$1/"; }

cmd_get() {
    api_ok GET "$1"
    jq . <<< "$BODY"
}

# Description HTML from stdin: markdown (default) or raw HTML with --html; empty when
# nothing came on stdin.
stdin_html() {
    local mode="$1" input=""
    [ -t 0 ] || input=$(cat)
    [ -n "$(printf '%s' "$input" | tr -d '[:space:]')" ] || return 0
    if [ "$mode" = "--html" ]; then printf '%s' "$input"; else printf '%s' "$input" | md_to_html; fi
}

cmd_update() {
    local key="$1"; shift
    local title="" desc=0 mode="" assign=0 iid pid patch='{}' me html
    while [ $# -gt 0 ]; do
        case "$1" in
            --title) title="${2:-}"; shift 2 ;;
            --description) desc=1; shift ;;
            --html) mode="--html"; shift ;;
            --assign-me) assign=1; shift ;;
            *) die "Unknown option for update: $1" ;;
        esac
    done
    [ -n "$title" ] || [ "$desc" = 1 ] || [ "$assign" = 1 ] || die "Usage: plane.sh update KEY [--title T] [--description] [--html] [--assign-me]"
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    [ -n "$title" ] && patch=$(jq -c --arg t "$title" '. + {name: $t}' <<< "$patch")
    if [ "$assign" = 1 ]; then
        me=$(me_id) || exit 1
        if issue_json "$key" | jq -e --arg me "$me" '[(.assignees // [])[] | if type == "object" then .id else . end] | index($me)' >/dev/null; then
            [ "$patch" = '{}' ] && [ "$desc" = 0 ] && { echo "$key already assigned to me"; return; }
        else
            patch=$(issue_json "$key" | jq -c --argjson p "$patch" --arg me "$me" \
                '$p + {assignees: ([(.assignees // [])[] | if type == "object" then .id else . end] + [$me])}')
        fi
    fi
    if [ "$desc" = 1 ]; then
        html=$(stdin_html "$mode") || exit 1
        [ -n "$html" ] || die "Empty description (pass it on stdin)."
        patch=$(jq -c --arg h "$html" '. + {description_html: $h}' <<< "$patch")
    fi
    api_ok PATCH "/workspaces/$WS/projects/$pid/work-items/$iid/" "$patch"
    echo "$key updated ($(jq -r 'keys | join(", ")' <<< "$patch"))"
}

module_id() {
    local pid="$1" name="$2" id
    id=$(api_all "/workspaces/$WS/projects/$pid/modules/" | jq -r --arg n "$name" '
        [.[] | select(.name | ascii_downcase == ($n | ascii_downcase))] + [.[] | select(.name | ascii_downcase | startswith($n | ascii_downcase))]
        | first | .id // empty')
    [ -n "$id" ] || die "No module matches '$name'."
    echo "$id"
}

state_id() {
    local pid="$1" name="$2" id
    id=$(api_all "/workspaces/$WS/projects/$pid/states/" | jq -r --arg n "$name" '.[] | select(.name | ascii_downcase == ($n | ascii_downcase)) | .id' | head -1)
    [ -n "$id" ] || die "No state named '$name'."
    echo "$id"
}

cmd_create() {
    local prefix; prefix=$(printf '%s' "${1%%-*}" | tr '[:lower:]' '[:upper:]'); shift
    local title="" parent="" module="" state="" priority="" mode="" pid body iid seq html pk par sid mid=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --title) title="${2:-}"; shift 2 ;;
            --parent) parent="${2:-}"; shift 2 ;;
            --module) module="${2:-}"; shift 2 ;;
            --state) state="${2:-}"; shift 2 ;;
            --priority) priority="${2:-}"; shift 2 ;;
            --html) mode="--html"; shift ;;
            *) die "Unknown option for create: $1" ;;
        esac
    done
    [ -n "$title" ] || die "Usage: plane.sh create PREFIX --title T [--parent KEY] [--module NAME] [--state NAME] [--priority P]"
    use_ws "$prefix"
    pid=$(project_id_for "$prefix") || exit 1
    body=$(jq -cn --arg t "$title" '{name: $t}')
    html=$(stdin_html "$mode") || exit 1
    [ -n "$html" ] && body=$(jq -c --arg h "$html" '. + {description_html: $h}' <<< "$body")
    if [ -n "$parent" ]; then
        pk=$(resolve_key "$parent") || exit 1
        same_ws "$pk"
        issue_json "$pk" >/dev/null || exit 1
        IFS=$'\t' read -r par _ <<< "$(issue_ids "$pk")"
        [ -n "$par" ] || exit 1
        body=$(jq -c --arg p "$par" '. + {parent: $p}' <<< "$body")
    fi
    if [ -n "$state" ]; then sid=$(state_id "$pid" "$state") || exit 1; body=$(jq -c --arg s "$sid" '. + {state: $s}' <<< "$body"); fi
    [ -n "$priority" ] && body=$(jq -c --arg p "$priority" '. + {priority: $p}' <<< "$body")
    if [ -n "$module" ]; then mid=$(module_id "$pid" "$module") || exit 1; fi
    api_ok POST "/workspaces/$WS/projects/$pid/work-items/" "$body"
    iid=$(jq -r .id <<< "$BODY"); seq=$(jq -r .sequence_id <<< "$BODY")
    if [ -n "$mid" ]; then
        api_ok POST "/workspaces/$WS/projects/$pid/modules/$mid/module-issues/" "$(jq -cn --arg i "$iid" '{issues: [$i]}')"
    fi
    echo "key=$prefix-$seq"
    echo "id=$iid"
}

cmd_add_state() {
    local prefix="${1%%-*}" name="$2" group="$3" color="${4:-#f59e0b}" sequence="${5:-}" pid body
    case "$group" in backlog|unstarted|started|completed|cancelled) ;;
        *) die "GROUP must be backlog, unstarted, started, completed or cancelled (got '$group')." ;; esac
    use_ws "$prefix"
    pid=$(project_id_for "$prefix") || exit 1
    if api_all "/workspaces/$WS/projects/$pid/states/" | jq -e --arg n "$name" 'any(.[]; .name | ascii_downcase == ($n | ascii_downcase))' >/dev/null; then
        echo "$prefix already has state $name"; return
    fi
    body=$(jq -cn --arg n "$name" --arg g "$group" --arg c "$color" --arg s "$sequence" \
        '{name: $n, group: $g, color: $c} + (if $s == "" then {} else {sequence: ($s | tonumber)} end)')
    api_ok POST "/workspaces/$WS/projects/$pid/states/" "$body"
    echo "$prefix state added: $(jq -r '[.id, .name, .group] | @tsv' <<< "$BODY")"
}

cmd_add_module() {
    local prefix="${1%%-*}" name="$2" status="${3:-planned}" pid body desc=""
    case "$status" in backlog|planned|in-progress|paused|completed|cancelled) ;;
        *) die "STATUS must be backlog, planned, in-progress, paused, completed or cancelled (got '$status')." ;; esac
    use_ws "$prefix"
    pid=$(project_id_for "$prefix") || exit 1
    if api_all "/workspaces/$WS/projects/$pid/modules/" | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
        echo "$prefix already has module $name"; return
    fi
    body=$(jq -cn --arg n "$name" --arg s "$status" '{name: $n, status: $s}')
    [ -t 0 ] || desc=$(cat)
    [ -n "$desc" ] && body=$(jq -c --arg d "$desc" '. + {description: $d}' <<< "$body")
    api_ok POST "/workspaces/$WS/projects/$pid/modules/" "$body"
    echo "$prefix module added: $(jq -r '[.id, .name] | @tsv' <<< "$BODY")"
}

cmd_modules() {
    local pid
    use_ws "$1"
    pid=$(project_id_for "$1") || exit 1
    api_all "/workspaces/$WS/projects/$pid/modules/" | jq -r '.[] | [.id, .name] | @tsv'
}

cmd_relations() {
    local key="$1" iid pid ids prefix map t id
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    api_ok GET "/workspaces/$WS/projects/$pid/work-items/$iid/relations/"
    ids=$(jq -r 'to_entries[] | select(.value | type == "array") | .key as $t | .value[] | [$t, (if type == "object" then (.issue_id // .id) else . end)] | @tsv' <<< "$BODY")
    [ -n "$ids" ] || return 0
    prefix="${key%%-*}"
    map=$(api_all "/workspaces/$WS/projects/$pid/work-items/" | jq -c --arg p "$prefix" 'map({key: .id, value: "\($p)-\(.sequence_id)"}) | from_entries')
    while IFS=$'\t' read -r t id; do
        printf '%s\t%s\n' "$t" "$(jq -r --arg i "$id" '.[$i] // $i' <<< "$map")"
    done <<< "$ids"
}

cmd_links() {
    local key="$1" iid pid
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    api_all "/workspaces/$WS/projects/$pid/work-items/$iid/links/" | jq -r '.[] | [.id, (.title // ""), .url] | @tsv'
}

cmd_link() {
    local key="$1" url="$2" title="${3:-}" iid pid
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    if api_all "/workspaces/$WS/projects/$pid/work-items/$iid/links/" | jq -e --arg u "$url" 'any(.[]; .url == $u)' >/dev/null; then
        echo "$key already links $url"; return
    fi
    api_ok POST "/workspaces/$WS/projects/$pid/work-items/$iid/links/" "$(jq -cn --arg u "$url" --arg t "$title" '{url: $u} + (if $t == "" then {} else {title: $t} end)')"
    echo "$key linked $url"
}

cmd_relate() {
    local key="$1" type="$2"; shift 2
    [ $# -ge 1 ] || die "Usage: plane.sh relate KEY TYPE OTHER..."
    local iid pid ids="[]" o oid
    issue_json "$key" >/dev/null || exit 1
    IFS=$'\t' read -r iid pid <<< "$(issue_ids "$key")"
    [ -n "$iid" ] || exit 1
    for o in "$@"; do
        o=$(resolve_key "$o") || exit 1
        same_ws "$o"
        issue_json "$o" >/dev/null || exit 1
        IFS=$'\t' read -r oid _ <<< "$(issue_ids "$o")"
        [ -n "$oid" ] || exit 1
        ids=$(jq -c --arg i "$oid" '. + [$i]' <<< "$ids")
    done
    api_ok POST "/workspaces/$WS/projects/$pid/work-items/$iid/relations/" "$(jq -cn --arg t "$type" --argjson i "$ids" '{relation_type: $t, issues: $i}')"
    echo "$key $type $*"
}

# Key from the first argument when it looks like one (or a browse URL), else from the
# session's task. Sets KEY, REST and the workspace.
KEY=""; REST=()
key_and_rest() {
    need_prefixes
    if [ -n "${1:-}" ] && printf '%s' "$1" | grep -qiE '^[A-Z][A-Z0-9]*-[0-9]+$|/browse/'; then
        KEY=$(resolve_key "$(printf '%s' "$1" | grep -oiE '[A-Z][A-Z0-9]*-[0-9]+' | tail -1)") || exit 1; shift
    else
        KEY=$(resolve_key "") || exit 1
    fi
    REST=("$@")
    use_ws "$KEY"
}
key_arg() {
    need_prefixes
    KEY=$(resolve_key "$(printf '%s' "$1" | grep -oiE '[A-Z][A-Z0-9]*-[0-9]+' | tail -1)") || exit 1
    use_ws "$KEY"
}

CMD="${1:-help}"; shift || true
case "$CMD" in
    help|-h|--help) sed -n '2,/^$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    init)           cmd_init "$@"; exit $? ;;
esac
load_config
case "$CMD" in
    key|session-name|figures|parse-time|logged|context|day|month|base-branch)
                   [ "$CMD" = parse-time ] || [ "$CMD" = base-branch ] || [ "$CMD" = session-name ] || need_prefixes
                   local_figures "$CMD" "$@" ;;
    mark-logged)   need_prefixes; local_figures mark-logged "$@" ;;
    add-workspace) cmd_add_workspace "$@" ;;
    check)         cmd_check ;;
    config)        cmd_config ;;
    issue)         key_and_rest "$@"; cmd_issue "$KEY" ;;
    comments)      key_and_rest "$@"; cmd_comments "$KEY" ;;
    worklogs)      key_and_rest "$@"; cmd_worklogs "$KEY" ${REST[@]+"${REST[@]}"} ;;
    worklog-days)  [ $# -ge 2 ] || die "Usage: plane.sh worklog-days FROM TO [--scan]"; need_prefixes; cmd_worklog_days "$@" ;;
    log-work)      key_and_rest "$@"; [ "${#REST[@]}" -ge 2 ] || die "Usage: plane.sh log-work [KEY] SECONDS STARTED [NOTE]"
                   cmd_log_work "$KEY" "${REST[0]}" "${REST[1]}" "${REST[2]:-}" ;;
    comment)       key_and_rest "$@"; cmd_comment "$KEY" "${REST[0]:-}" ;;
    states)        key_and_rest "$@"; cmd_states "$KEY" ;;
    move)          key_and_rest "$@"; [ "${#REST[@]}" -ge 1 ] || die "Usage: plane.sh move [KEY] start|close|done|<state>"
                   cmd_move "$KEY" "${REST[*]}" ;;
    ledger-check)  need_prefixes; k=""; if [ -n "${1:-}" ]; then k=$(resolve_key "$1") || exit 1; fi; cmd_ledger_check "$k" ;;
    forget)        [ -n "${1:-}" ] || die "Usage: plane.sh forget COMMENT_ID"; cmd_forget "$1" ;;
    mine)          cmd_mine ;;
    url)           key_and_rest "$@"; cmd_url "$KEY" ;;
    get)           [ -n "${1:-}" ] || die "Usage: plane.sh get PATH"
                   w=$(printf '%s' "$1" | sed -n 's#^\(/api/v1\)\{0,1\}/workspaces/\([^/?]*\).*#\2#p'); [ -n "$w" ] && set_ws "$w"
                   cmd_get "$1" ;;
    update)        [ -n "${1:-}" ] || die "Usage: plane.sh update KEY [--title T] [--description] [--html] [--assign-me]"
                   key_arg "$1"; shift; cmd_update "$KEY" "$@" ;;
    create)        [ -n "${1:-}" ] || die "Usage: plane.sh create PREFIX --title T ..."; need_prefixes; cmd_create "$@" ;;
    modules)       [ -n "${1:-}" ] || die "Usage: plane.sh modules PREFIX"; need_prefixes; cmd_modules "$1" ;;
    add-state)     [ $# -ge 3 ] || die "Usage: plane.sh add-state PREFIX NAME GROUP [COLOR] [SEQUENCE]"; need_prefixes; cmd_add_state "$@" ;;
    add-module)    [ $# -ge 2 ] || die "Usage: plane.sh add-module PREFIX NAME [STATUS]"; need_prefixes; cmd_add_module "$@" ;;
    relations)     key_and_rest "$@"; cmd_relations "$KEY" ;;
    links)         key_and_rest "$@"; cmd_links "$KEY" ;;
    link)          [ $# -ge 2 ] || die "Usage: plane.sh link KEY URL [TITLE]"
                   key_arg "$1"; cmd_link "$KEY" "$2" "${3:-}" ;;
    relate)        [ $# -ge 3 ] || die "Usage: plane.sh relate KEY TYPE OTHER..."
                   key_arg "$1"; shift; cmd_relate "$KEY" "$@" ;;
    *)             die "Unknown command: $CMD (try: plane.sh help)" ;;
esac
