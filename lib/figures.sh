#!/usr/bin/env bash
# Local figures for plane.sh: a copy of bin/jira.sh from the jira-worklog plugin
# (github.com/jfeid/claude-jira), kept in step with it. plane.sh runs it with
# JIRA_HOME=PLANE_HOME, KEY_PREFIX_INCLUDE=<the Plane prefixes>, KEY_TRACKER=Plane and
# KEY_COMMAND=/plane; it never talks to Plane or Jira. Below, jira.sh means this file.
#
#   jira.sh key [KEY|URL]           resolve a ticket key: the argument, else the session's task
#   jira.sh session-name            the session's name, when it can be a task (from timer.sh)
#   jira.sh figures [KEY]           worklog figures from the timer log, minus time already logged
#   jira.sh parse-time "1h 30m"     convert a Jira duration to seconds
#   jira.sh mark-logged KEY SECONDS [WORKLOG_ID] [NOTE] [STARTED]
#                                   record a worklog in the ledger so it is not logged twice
#                                   (STARTED: the worklog's started value, ISO 8601 or epoch)
#   jira.sh logged [KEY]            ledger entries (all keys when KEY is omitted)
#   jira.sh day [DATE] [--here]     full-day report: per ticket time tracked that day, ledger
#                                   worklogs for that day and the unlogged remainder, over every
#                                   project (--here: current project only). DATE defaults to today.
#   jira.sh month [MM-YYYY] [--here]
#                                   month report: every day with timer records or ledger worklogs,
#                                   billable time (per ticket per day, rounded up, summed) per day
#                                   and per ticket, ledger worklogs and the unlogged remainder
#   jira.sh context [KEY]           branch, commits and task docs mentioning KEY (for closing notes)
#   jira.sh url [KEY]               browse URL for the ticket
#   jira.sh base-branch             the branch new work starts from and production deploys
#   jira.sh staging-keys [STAGING_REF] [PROD_REF]
#                                   ticket keys on staging but not on production: remote branches
#                                   merged into STAGING_REF and not into PROD_REF, plus keys in the
#                                   subjects of commits only on STAGING_REF (defaults
#                                   origin/<staging.branch>, origin/<base branch>; fetch first)
#   jira.sh init CLOUD_ID SITE_URL  write the config file with default settings
#   jira.sh config                  print the settings (with defaults) and the config file
#
# Config : $JIRA_HOME/config.json          (JIRA_HOME defaults to ~/.claude/jira)
# Ledger : $JIRA_HOME/logs/<project>.tsv   key, seconds, worklog_id, epoch, timestamp, note, started_epoch
# Timer  : the worklog-timer plugin's timer.sh and its logs, only read here

set -uo pipefail

ROOT="${JIRA_HOME:-$HOME/.claude/jira}"
CONFIG="$ROOT/config.json"
# timer.sh comes from the worklog-timer plugin, which puts it on the Bash tool's PATH.
TIMER_BIN="${TIMER_BIN:-$(command -v timer.sh 2>/dev/null)}"
QUARTER="${TIMER_QUARTER:-900}"   # rounding granularity in seconds, same default as timer.sh
KEY_RE='[A-Z][A-Z0-9]+-[0-9]+'

die() { echo "$*" >&2; exit 1; }

need_timer() {
    [ -n "$TIMER_BIN" ] && [ -x "$TIMER_BIN" ] ||
        die "timer.sh not found. Install the worklog-timer plugin (jfeid/claude-timer) or set TIMER_BIN."
}

# ---- config -----------------------------------------------------------------

# cfg PATH: one value from the config by jq path (.siteUrl, .staging.branch);
# arrays are joined with spaces. Without jq: the first "key": value pair whose
# key is the path's last part.
cfg() {
    [ -r "$CONFIG" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r "$1"' // empty | if type == "array" then join(" ") else tostring end' "$CONFIG" 2>/dev/null
        return 0
    fi
    local k="${1##*.}"
    tr -d '\r\n' < "$CONFIG" |
        grep -oE "\"$k\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|\[[^]]*\])" | head -1 |
        sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*//; s/^\[//; s/\]$//; s/"//g; s/,/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# Keys owned by another tracker. KEY_PREFIX_INCLUDE limits keys to those
# prefixes; otherwise keys with a prefix in KEY_PREFIX_EXCLUDE, or in the
# config's excludePrefixes, are refused. KEY_TRACKER names the tracker in messages.
PREFIX_INCLUDE="${KEY_PREFIX_INCLUDE:-}"
if [ -n "${KEY_PREFIX_EXCLUDE+set}" ]; then PREFIX_EXCLUDE="$KEY_PREFIX_EXCLUDE"
else PREFIX_EXCLUDE="$(cfg .excludePrefixes)"; fi
TRACKER="${KEY_TRACKER:-Jira}"

key_allowed() {
    local p="${1%%-*}"
    if [ -n "$PREFIX_INCLUDE" ]; then [[ " $PREFIX_INCLUDE " == *" $p "* ]]
    else [[ " $PREFIX_EXCLUDE " != *" $p "* ]]; fi
}

# Keep TSV rows whose key in column COL (bare KEY or project/KEY) passes key_allowed.
filter_keys() {
    awk -F'\t' -v c="$1" -v inc=" $PREFIX_INCLUDE " -v exc=" $PREFIX_EXCLUDE " '{
        k=$c; sub(/.*\//, "", k); split(k, a, "-"); p=" " a[1] " "
        if (inc != "  ") { if (index(inc, p)) print } else if (!index(exc, p)) print }'
}

# ---- dates: GNU date (Linux, Git Bash, gdate on macOS) or BSD date (macOS) ---

if date -d @0 +%s >/dev/null 2>&1; then GDATE=date
elif command -v gdate >/dev/null 2>&1; then GDATE=gdate
else GDATE=""; fi

gnu_date() {
    if [ "$GDATE" = gdate ]; then gdate "$@"; else date "$@"; fi
}

# YYYY-MM-DD for a date spec. BSD date knows today, yesterday, tomorrow and
# YYYY-MM-DD; anything else ("last friday") needs GNU date.
day_of() {
    local spec="${1:-today}"
    if [ -n "$GDATE" ]; then gnu_date -d "$spec" +%Y-%m-%d 2>/dev/null; return; fi
    case "$spec" in
        today)     date +%Y-%m-%d ;;
        yesterday) date -v-1d +%Y-%m-%d ;;
        tomorrow)  date -v+1d +%Y-%m-%d ;;
        [0-9][0-9][0-9][0-9]-[0-9]*-[0-9]*)
            date -j -f %Y-%m-%d "$spec" +%Y-%m-%d 2>/dev/null ;;
        *)  echo "macOS date reads today, yesterday, tomorrow or YYYY-MM-DD;" \
                 "install coreutils (brew install coreutils) for '$spec'." >&2
            return 1 ;;
    esac
}

midnight() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1 00:00:00" +%s
    else date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s; fi
}

signed() { if [ "$1" -lt 0 ]; then echo "- $(( -$1 ))"; else echo "+ $1"; fi; }
signed_bsd() { if [ "$1" -lt 0 ]; then echo "$1"; else echo "+$1"; fi; }
add_days() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1 $(signed "$2") day" +%Y-%m-%d
    else date -j -v"$(signed_bsd "$2")"d -f %Y-%m-%d "$1" +%Y-%m-%d; fi
}
add_months() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1 $(signed "$2") month" +%Y-%m-%d
    else date -j -v"$(signed_bsd "$2")"m -f %Y-%m-%d "$1" +%Y-%m-%d; fi
}

fmt_epoch() {
    if [ -n "$GDATE" ]; then gnu_date -d "@$1" "+$2"; else date -r "$1" "+$2"; fi
}
fmt_day() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1" "+$2"; else date -j -f %Y-%m-%d "$1" "+$2"; fi
}

# Epoch of an epoch, an ISO 8601 time (2026-09-07T11:24:00.000+0300, Z, +03:00),
# "YYYY-MM-DD HH:MM[:SS]" or "YYYY-MM-DD" (local midnight).
to_epoch() {
    local s="$1" base tz
    [[ "$s" =~ ^[0-9]+$ ]] && { echo "$s"; return 0; }
    s=$(printf '%s' "$s" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/; s/^([0-9-]{10}) /\1T/')
    if [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then midnight "$s"; return; fi
    [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2})(:[0-9]{2})?([+-][0-9]{4})?$ ]] || return 1
    base="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}${BASH_REMATCH[3]:-:00}"
    tz="${BASH_REMATCH[4]}"
    if [ -n "$GDATE" ]; then gnu_date -d "$base$tz" +%s 2>/dev/null
    elif [ -n "$tz" ]; then date -j -f '%Y-%m-%d %H:%M:%S%z' "$base$tz" +%s 2>/dev/null
    else date -j -f '%Y-%m-%d %H:%M:%S' "$base" +%s 2>/dev/null; fi
}

iso() { fmt_epoch "$1" '%Y-%m-%dT%H:%M:%S.000%z'; }

# ---- project, ledger, timer log ---------------------------------------------

# The timer's project and log: timer.sh decides (session task's project, else
# the git top-level folder name), so both logs always agree.
TIMER_LOG=""
if [ -n "$TIMER_BIN" ] && [ -x "$TIMER_BIN" ]; then
    TIMER_LOG=$("$TIMER_BIN" where 2>/dev/null)
fi
TIMER_ROOT="${TIMER_HOME:-$HOME/.claude/timer}"
if [ -n "$TIMER_LOG" ]; then
    TIMER_ROOT=$(dirname "$(dirname "$TIMER_LOG")")
    PROJECT=$(basename "$TIMER_LOG" .tsv)
elif [ -n "${TIMER_PROJECT:-}" ]; then
    PROJECT="$TIMER_PROJECT"
else
    top=$(git rev-parse --show-toplevel 2>/dev/null)
    [ -z "$top" ] && top="$(pwd)"
    PROJECT=$(printf '%s' "$(basename "$top")" | tr -c 'A-Za-z0-9._-' '-')
fi
[ -n "$TIMER_LOG" ] || TIMER_LOG="$TIMER_ROOT/logs/$PROJECT.tsv"
LEDGER="$ROOT/logs/$PROJECT.tsv"

# ---- keys ---------------------------------------------------------------------

session_task() {
    if [ -n "${JIRA_SESSION_TASK+set}" ]; then printf '%s' "$JIRA_SESSION_TASK"; return; fi
    [ -n "$TIMER_BIN" ] && [ -x "$TIMER_BIN" ] && "$TIMER_BIN" session-task 2>/dev/null
}

# Key from the argument (bare key or Jira URL), else from the session's task.
resolve_key() {
    local raw="${1:-}" src="argument" key
    if [ -z "$raw" ]; then
        raw=$(session_task); src="session's task"
        [ -z "$raw" ] && die "No ticket key given and this session has no task. Use: ${KEY_COMMAND:-/jira} <action> KEY, or /rename KEY first."
    fi
    key=$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' | grep -oE "$KEY_RE" | head -1)
    [ -z "$key" ] && die "No $TRACKER key (like ABC-123) found in the $src '$raw'."
    if ! key_allowed "$key"; then
        if [ -n "$PREFIX_INCLUDE" ]; then die "$key is not a $TRACKER key (prefixes: $PREFIX_INCLUDE)."
        else die "$key is excluded from $TRACKER (excludePrefixes: $PREFIX_EXCLUDE)."; fi
    fi
    echo "$key"
}

# ---- figures ------------------------------------------------------------------

fmt() {
    awk -v s="$1" 'BEGIN{
        if (s<0) s=0; h=int(s/3600); m=int((s%3600)/60);
        if (h>0) printf "%dh %02dm", h, m; else printf "%dm", m }'
}

# Jira "timeSpent" syntax: 2h, 1h 15m, 45m
jira_time() {
    awk -v s="$1" 'BEGIN{
        if (s<=0) { print "0m"; exit }
        h=int(s/3600); m=int((s%3600)/60);
        if (h>0 && m>0) printf "%dh %dm\n", h, m; else if (h>0) printf "%dh\n", h; else printf "%dm\n", m }'
}

roundup() {
    awk -v s="$1" -v q="$QUARTER" 'BEGIN{ if (s<=0) { print 0; exit } print int((s + q - 1) / q) * q }'
}

hours() { LC_ALL=C awk -v s="$1" 'BEGIN{printf "%.2f", s/3600}'; }

# Tracked seconds and state for KEY in a timer log: "<seconds>\t<STATE>"
timer_totals() {
    local log="${2:-$TIMER_LOG}"
    [ -s "$log" ] || { printf '0\tNONE\n'; return; }
    awk -F'\t' -v k="$1" -v now="$(date +%s)" '
        $1==k {
            ev=$2; ts=$3;
            if (ev=="START" || ev=="RESUME") { if (!open) open=ts }
            else if (ev=="PAUSE" || ev=="STOP") { if (open) { tot+=ts-open; open=0 } }
            last=ev; seen=1
        }
        END {
            if (!seen) { printf "0\tNONE\n"; exit }
            st="STOPPED"; if (open) { tot+=now-open; st="RUNNING" } else if (last=="PAUSE") st="PAUSED";
            printf "%d\t%s\n", tot, st
        }' "$log"
}

ledger_seconds() {
    local l="${2:-$LEDGER}"
    [ -s "$l" ] || { echo 0; return; }
    awk -F'\t' -v k="$1" '$1==k{s+=$2} END{printf "%d", s+0}' "$l"
}
ledger_last_epoch() {
    [ -s "$LEDGER" ] || { echo 0; return; }
    awk -F'\t' -v k="$1" '$1==k{e=$4} END{printf "%d", e+0}' "$LEDGER"
}

# Epoch of the first START/RESUME of KEY at or after EPOCH (empty when none).
first_start_after() {
    [ -s "$TIMER_LOG" ] || return 0
    awk -F'\t' -v k="$1" -v after="$2" '$1==k && ($2=="START"||$2=="RESUME") && $3>=after { print $3; exit }' "$TIMER_LOG"
}

last_event_stamp() {
    [ -s "$TIMER_LOG" ] || return 0
    awk -F'\t' -v k="$1" '$1==k{e=$3} END{print e}' "$TIMER_LOG"
}

cmd_figures() {
    local key="$1" tot st logged unlogged rounded after start_epoch last
    IFS=$'\t' read -r tot st <<< "$(timer_totals "$key")"
    logged=$(ledger_seconds "$key")
    unlogged=$((tot - logged)); [ "$unlogged" -lt 0 ] && unlogged=0
    rounded=$(roundup "$unlogged")
    after=$(ledger_last_epoch "$key")
    start_epoch=$(first_start_after "$key" "$after")
    [ -z "$start_epoch" ] && start_epoch=$(first_start_after "$key" 0)
    [ -z "$start_epoch" ] && start_epoch=$(date +%s)
    last=$(last_event_stamp "$key")
    echo "key=$key"
    echo "project=$PROJECT"
    echo "timer_state=$st"
    echo "tracked_seconds=$tot"
    echo "tracked=$(fmt "$tot")"
    echo "logged_seconds=$logged"
    echo "logged=$(fmt "$logged")"
    echo "unlogged_seconds=$unlogged"
    echo "rounded_seconds=$rounded"
    echo "time_spent=$(jira_time "$rounded")"
    echo "started=$(iso "$start_epoch")"
    echo "last_event=${last:+$(fmt_epoch "$last" '%Y-%m-%d %H:%M:%S')}"
    echo "timer_log=$TIMER_LOG"
    echo "ledger=$LEDGER"
}

cmd_parse_time() {
    local in="$*" s total=0 n u
    s=$(printf '%s' "$in" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    [ -z "$s" ] && die "Empty duration."
    while [ -n "$s" ]; do
        n=$(printf '%s' "$s" | grep -oE '^[0-9]+(\.[0-9]+)?') || die "Cannot parse duration '$in' (use e.g. 1h 30m)."
        s="${s#"$n"}"
        u="${s:0:1}"; s="${s:1}"
        case "$u" in
            w) total=$(awk -v t="$total" -v n="$n" 'BEGIN{printf "%d", t + n*144000}') ;;
            d) total=$(awk -v t="$total" -v n="$n" 'BEGIN{printf "%d", t + n*28800}') ;;
            h) total=$(awk -v t="$total" -v n="$n" 'BEGIN{printf "%d", t + n*3600}') ;;
            m) total=$(awk -v t="$total" -v n="$n" 'BEGIN{printf "%d", t + n*60}') ;;
            *) die "Cannot parse duration '$in' (use e.g. 1h 30m)." ;;
        esac
    done
    echo "$total"
}

cmd_mark_logged() {
    local key="$1" secs="${2:-}" id="${3:-}" note="${4:-}" started="${5:-}" started_epoch=""
    [[ "$secs" =~ ^[0-9]+$ ]] || die "SECONDS must be an integer (got '$secs')."
    note=$(printf '%s' "$note" | tr '\t\n' '  ')
    if [ -n "$started" ]; then
        started_epoch=$(to_epoch "$started") && [ -n "$started_epoch" ] ||
            die "Cannot parse STARTED '$started' (ISO 8601 or epoch)."
    fi
    mkdir -p "$ROOT/logs" 2>/dev/null &&
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$secs" "${id:--}" "$(date +%s)" \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$note" "$started_epoch" >> "$LEDGER" 2>/dev/null ||
        die "jira: cannot write $LEDGER"
    echo "$key: $(fmt "$secs") recorded as logged (worklog ${id:-?}${started_epoch:+, started $(fmt_epoch "$started_epoch" '%Y-%m-%d %H:%M')})"
}

cmd_logged() {
    local key="${1:-}" k s id e stamp note started
    if [ ! -s "$LEDGER" ]; then echo "No worklogs recorded yet for $PROJECT."; return; fi
    printf '%-12s %-9s %-10s %-19s %-16s %s\n' KEY TIME WORKLOG WHEN STARTED NOTE
    awk -F'\t' -v k="$key" 'k=="" || $1==k' "$LEDGER" | while IFS=$'\t' read -r k s id e stamp note started; do
        printf '%-12s %-9s %-10s %-19s %-16s %s\n' "$k" "$(fmt "$s")" "$id" "$stamp" \
            "${started:+$(fmt_epoch "$started" '%Y-%m-%d %H:%M')}" "$note"
    done
}

cmd_context() {
    local key="$1" top
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository."; return; }
    echo "repo=$top"
    echo "branch=$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "--- commits mentioning $key (newest first)"
    git -C "$top" log --all -i --oneline --grep="$key" -n 30 2>/dev/null
    echo "--- files touched by those commits"
    git -C "$top" log --all -i --grep="$key" --name-only --pretty=format: -n 30 2>/dev/null | awk 'NF && !seen[$0]++' | head -40
    echo "--- task docs"
    find "$top/docs" "$top/notes" -maxdepth 2 -iname "*$key*" 2>/dev/null
    echo "--- timer"
    [ -n "$TIMER_BIN" ] && [ -x "$TIMER_BIN" ] && "$TIMER_BIN" list 2>/dev/null | awk -v k="$key" 'NR==1 || $1==k'
}

# Ledger files: this project's with --here, else every project's.
ledger_files() {
    local f
    if [ "$1" = "1" ]; then printf '%s\n' "$LEDGER"; return; fi
    for f in "$ROOT"/logs/*.tsv; do [ -e "$f" ] && printf '%s\n' "$f"; done
}

# ---- day report -------------------------------------------------------------

# Ledger seconds for KEY in PROJECT whose worklog belongs to the day [A, Z):
# by the recorded started epoch (column 7) when present, else by when it was logged.
ledger_day_seconds() {
    local ledger="$ROOT/logs/$1.tsv"
    [ -s "$ledger" ] || { echo 0; return; }
    awk -F'\t' -v k="$2" -v a="$3" -v z="$4" '
        $1==k { e=($7!="" ? $7 : $4); if (e>=a && e<z) s+=$2 }
        END { printf "%d", s+0 }' "$ledger"
}

cmd_day() {
    local here=0 when="" a day day_start day_end rows
    for a in "$@"; do
        case "$a" in --here) here=1 ;; --all) ;; *) when="${when:+$when }$a" ;; esac
    done
    day=$(day_of "${when:-today}") && [ -n "$day" ] || die "Cannot understand date '$when'."
    day_start=$(midnight "$day")
    day_end=$(midnight "$(add_days "$day" 1)")
    need_timer

    if [ "$here" = "1" ]; then
        rows=$("$TIMER_BIN" day "$day" --tsv)
    else
        rows=$("$TIMER_BIN" day "$day" --tsv --all)
    fi
    rows=$(printf '%s\n' "$rows" | awk 'NF' | filter_keys 2)

    echo "day=$day"
    echo "weekday=$(LC_ALL=C fmt_day "$day" %A)"
    echo "scope=$([ "$here" = "1" ] && echo "$PROJECT" || echo all)"
    echo "generated=$(date '+%Y-%m-%d %H:%M:%S')"
    if [ -z "$rows" ]; then
        echo "tickets=0"
        echo "No time tracked on $day."
    else
        local p k s r f l st logged_day tot_all logged_all unlogged unl_r
        local g_s=0 g_r=0 g_ld=0 g_unl=0 n=0
        local table="" blocks=""
        while IFS=$'\t' read -r p k s r f l st; do
            [ -z "$k" ] && continue
            n=$((n+1))
            logged_day=$(ledger_day_seconds "$p" "$k" "$day_start" "$day_end")
            IFS=$'\t' read -r tot_all _ <<< "$(timer_totals "$k" "$TIMER_ROOT/logs/$p.tsv")"
            logged_all=$(ledger_seconds "$k" "$ROOT/logs/$p.tsv")
            unlogged=$((tot_all - logged_all)); [ "$unlogged" -lt 0 ] && unlogged=0
            unl_r=$(roundup "$unlogged")
            g_s=$((g_s+s)); g_r=$((g_r+r)); g_ld=$((g_ld+logged_day)); g_unl=$((g_unl+unl_r))
            table+=$(printf '%-15s %-12s %-8s %-8s %-8s %-8s %-6s %-6s %s' "$p" "$k" "$(fmt "$s")" "$(fmt "$r")" \
                "$(fmt "$logged_day")" "$(fmt "$unl_r")" "$(fmt_epoch "$f" %H:%M)" "$(fmt_epoch "$l" %H:%M)" "$st")$'\n'
            blocks+="[$k]"$'\n'
            blocks+="project=$p"$'\n'
            blocks+="tracked_day_seconds=$s"$'\n'
            blocks+="tracked_day=$(fmt "$s")"$'\n'
            blocks+="rounded_day=$(fmt "$r")"$'\n'
            blocks+="first=$(fmt_epoch "$f" %H:%M)"$'\n'
            blocks+="last=$(fmt_epoch "$l" %H:%M)"$'\n'
            blocks+="timer_state=$st"$'\n'
            blocks+="logged_day_seconds=$logged_day"$'\n'
            blocks+="tracked_total_seconds=$tot_all"$'\n'
            blocks+="logged_total_seconds=$logged_all"$'\n'
            blocks+="unlogged_seconds=$unlogged"$'\n'
            blocks+="unlogged_rounded_seconds=$unl_r"$'\n'
            blocks+="time_spent=$(jira_time "$unl_r")"$'\n'
            blocks+="started=$(iso "$f")"$'\n'
            blocks+=$'\n'
        done <<< "$rows"

        echo "tickets=$n"
        echo
        printf '%-15s %-12s %-8s %-8s %-8s %-8s %-6s %-6s %s\n' PROJECT KEY TRACKED ROUNDED LOGGED UNLOGGED FIRST LAST STATE
        printf '%s\n' "-------------------------------------------------------------------------------------"
        printf '%s' "$table"
        printf '%s\n' "-------------------------------------------------------------------------------------"
        printf '%-15s %-12s %-8s %-8s %-8s %-8s\n' "" TOTAL "$(fmt "$g_s")" "$(fmt "$g_r")" "$(fmt "$g_ld")" "$(fmt "$g_unl")"
        echo
        echo "TRACKED/ROUNDED: time on $day. LOGGED: ledger worklogs for $day."
        echo "UNLOGGED: whole remainder for the ticket (all days), rounded up; this is what a worklog would take."
        echo
        printf '%s' "$blocks"
        echo "--- timeline"
        # Timeline lines: "HH:MM-HH:MM  [project/]KEY  duration"; keep this tracker's keys.
        if [ "$here" = "1" ]; then
            "$TIMER_BIN" day "$day"
        else
            "$TIMER_BIN" day "$day" --all
        fi | sed -n '/^Timeline$/,$p' | sed 1d | awk '{ k=$2; printf "%s\t%s\n", k, $0 }' | filter_keys 1 | cut -f2-
    fi

    # Worklogs filed under the day, even when no timer ran (logged by hand from here).
    echo "--- ledger entries for $day"
    local lg any=0 ref
    while IFS= read -r lg; do
        [ -s "$lg" ] || continue
        p=$(basename "$lg" .tsv)
        while IFS=$'\t' read -r k s id e stamp note started; do
            [ -z "$k" ] && continue
            key_allowed "$k" || continue
            ref="${started:-$e}"
            if [ "$ref" -ge "$day_start" ] && [ "$ref" -lt "$day_end" ]; then
                any=1
                printf '%-15s %-12s %-8s %-8s %s  %s\n' "$p" "$k" "$(fmt "$s")" "$id" "$(fmt_epoch "$ref" '%H:%M')" "$note"
            fi
        done < "$lg"
    done < <(ledger_files "$here")
    [ "$any" = "0" ] && echo "none"
    return 0
}

# ---- month report -----------------------------------------------------------

# Same parsing as `timer.sh month`: MM-YYYY, M-YYYY, YYYY-MM, "last"; default current month.
# Sets MONTH (YYYY-MM), MONTH_START, MONTH_END (epoch, end exclusive).
month_bounds() {
    local in="${1:-}" m y
    case "$in" in
        "")                 m=$(date +%m); y=$(date +%Y) ;;
        last|prev|previous) in=$(add_months "$(date +%Y-%m-01)" -1); in=${in%-*}; y=${in%-*}; m=${in#*-} ;;
        *)
            if [[ "$in" =~ ^([0-9]{1,2})[-/.]([0-9]{4})$ ]]; then m=${BASH_REMATCH[1]}; y=${BASH_REMATCH[2]}
            elif [[ "$in" =~ ^([0-9]{4})[-/.]([0-9]{1,2})$ ]]; then y=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
            else return 1; fi ;;
    esac
    m=$((10#$m))
    [ "$m" -ge 1 ] && [ "$m" -le 12 ] || return 1
    MONTH=$(printf '%04d-%02d' "$((10#$y))" "$m")
    MONTH_START=$(midnight "$MONTH-01")
    MONTH_END=$(midnight "$(add_months "$MONTH-01" 1)")
}

cmd_month() {
    local here=0 when="" a rows lg p e k s
    for a in "$@"; do
        case "$a" in --here) here=1 ;; --all) ;; *) when="${when:+$when }$a" ;; esac
    done
    month_bounds "$when" || die "Cannot understand month '$when' (use MM-YYYY, e.g. 09-2026)."
    need_timer

    # Timer rows: date, project, task, seconds, rounded, state
    if [ "$here" = "1" ]; then
        rows=$("$TIMER_BIN" month "$MONTH" --tsv)
    else
        rows=$("$TIMER_BIN" month "$MONTH" --tsv --all)
    fi
    rows=$(printf '%s\n' "$rows" | awk 'NF' | filter_keys 3)

    # Ledger worklogs filed under a day of the month (started epoch, else when logged):
    # L <TAB> date <TAB> project <TAB> key <TAB> seconds
    local led=""
    while IFS= read -r lg; do
        [ -s "$lg" ] || continue
        p=$(basename "$lg" .tsv)
        while IFS=$'\t' read -r e k s; do
            key_allowed "$k" || continue
            led+=$(printf 'L\t%s\t%s\t%s\t%s' "$(fmt_epoch "$e" %Y-%m-%d)" "$p" "$k" "$s")$'\n'
        done < <(awk -F'\t' -v OFS='\t' -v a="$MONTH_START" -v z="$MONTH_END" '
            NF { e=($7!="" ? $7 : $4); if (e>=a && e<z) print e, $1, $2 }' "$lg")
    done < <(ledger_files "$here")

    local all
    all=$(printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' 'NF { print "T", $0 }'; printf '%s' "$led" | awk 'NF')

    local t_s t_r t_l n_days n_keys
    read -r t_s t_r t_l n_days n_keys < <(printf '%s\n' "$all" | awk -F'\t' '
        $1=="T" { s+=$5; r+=$6; d[$2]=1; k[$3 SUBSEP $4]=1 }
        $1=="L" { l+=$5 }
        END { for (x in d) nd++; for (x in k) nk++; printf "%d %d %d %d %d\n", s, r, l, nd, nk }')

    echo "month=$MONTH"
    echo "month_name=$(LC_ALL=C fmt_day "$MONTH-01" '%B %Y')"
    echo "first_day=$MONTH-01"
    echo "last_day=$(fmt_epoch "$((MONTH_END - 1))" %Y-%m-%d)"
    echo "scope=$([ "$here" = "1" ] && echo "$PROJECT" || echo all)"
    echo "generated=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "days=$n_days"
    echo "tickets=$n_keys"
    echo "tracked_seconds=$t_s"
    echo "tracked=$(fmt "$t_s")"
    echo "billable_seconds=$t_r"
    echo "billable=$(fmt "$t_r")"
    echo "billable_hours=$(hours "$t_r")"
    echo "logged_seconds=$t_l"
    echo "logged=$(fmt "$t_l")"
    echo "logged_hours=$(hours "$t_l")"
    if [ -z "$(printf '%s' "$all" | awk 'NF')" ]; then
        echo "No time tracked or logged in $MONTH."
        return 0
    fi

    local awk_fmt='function fmt(s,  h,m) { if (s<0) s=0; h=int(s/3600); m=int((s%3600)/60); return (h>0 ? sprintf("%dh %02dm", h, m) : sprintf("%dm", m)) }'

    echo
    echo "--- days"
    printf '%-11s %-4s %-8s %-8s %-9s %s\n' DATE DAY TICKETS TRACKED BILLABLE LOGGED
    printf '%s\n' "----------------------------------------------------------------"
    local d n r l
    while IFS=$'\t' read -r d n s r l; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$(LC_ALL=C fmt_day "$d" %a)" "$n" "$s" "$r" "$l"
    done < <(printf '%s\n' "$all" | awk -F'\t' -v OFS='\t' '
        $1=="T" { n[$2]++; s[$2]+=$5; r[$2]+=$6; seen[$2]=1 }
        $1=="L" { l[$2]+=$5; seen[$2]=1 }
        END { for (d in seen) print d, n[d]+0, s[d]+0, r[d]+0, l[d]+0 }' | sort) | awk -F'\t' "$awk_fmt"'
        { printf "%-11s %-4s %-8s %-8s %-9s %s\n", $1, $2, ($3 ? $3 : "-"), ($4 ? fmt($4) : "-"), ($5 ? fmt($5) : "-"), ($6 ? fmt($6) : "-") }'
    printf '%s\n' "----------------------------------------------------------------"
    printf '%-11s %-4s %-8s %-8s %-9s %s\n' TOTAL "" "$n_keys" "$(fmt "$t_s")" "$(fmt "$t_r")" "$(fmt "$t_l")"

    echo
    echo "--- tickets"
    printf '%-15s %-12s %-5s %-8s %-9s %-8s %-9s %-11s %-11s %s\n' PROJECT KEY DAYS TRACKED BILLABLE LOGGED UNLOGGED FIRST LAST STATE
    printf '%s\n' "------------------------------------------------------------------------------------------------"
    local f z st tot_all logged_all unlogged unl_r g_unl=0
    while IFS=$'\t' read -r p k n s r l f z st; do
        [ -z "$k" ] && continue
        IFS=$'\t' read -r tot_all a <<< "$(timer_totals "$k" "$TIMER_ROOT/logs/$p.tsv")"
        logged_all=$(ledger_seconds "$k" "$ROOT/logs/$p.tsv")
        unlogged=$((tot_all - logged_all)); [ "$unlogged" -lt 0 ] && unlogged=0
        unl_r=$(roundup "$unlogged"); g_unl=$((g_unl + unl_r))
        [ -z "$st" ] && st="$a"
        printf '%-15s %-12s %-5s %-8s %-9s %-8s %-9s %-11s %-11s %s\n' "$p" "$k" "$n" "$(fmt "$s")" "$(fmt "$r")" \
            "$(fmt "$l")" "$(fmt "$unl_r")" "${f:--}" "${z:--}" "$st"
    done < <(printf '%s\n' "$all" | awk -F'\t' -v OFS='\t' '
        NF { key=$3 SUBSEP $4; if (!(key in seen)) { seen[key]=1; order[++m]=key } }
        $1=="T" { n[key]++; s[key]+=$5; r[key]+=$6; if (!(key in tf)) tf[key]=$2; tl[key]=$2; st[key]=$7 }
        $1=="L" { l[key]+=$5 }
        END {
            # timer rows are already in date order; ledger-only keys go last
            for (i=1;i<=m;i++) { key=order[i]; split(key,x,SUBSEP)
                print (key in tf ? tf[key] : "9999"), x[1], x[2], n[key]+0, s[key]+0, r[key]+0, l[key]+0, tf[key], tl[key], st[key] }
        }' | sort -t$'\t' -k1,1 -s | cut -f2-)
    printf '%s\n' "------------------------------------------------------------------------------------------------"
    printf '%-15s %-12s %-5s %-8s %-9s %-8s %s\n' "" TOTAL "$n_days" "$(fmt "$t_s")" "$(fmt "$t_r")" "$(fmt "$t_l")" "$(fmt "$g_unl")"
    echo
    echo "BILLABLE: per ticket per day rounded up to the quarter, summed ($(hours "$t_r") h). LOGGED: ledger"
    echo "worklogs filed under $MONTH. UNLOGGED: whole remainder per ticket (all days), rounded up."
}

# ---- git, config --------------------------------------------------------------

base_branch() {
    local b
    b=$(cfg .baseBranch)
    [ -n "$b" ] && { echo "$b"; return; }
    b=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
    [ -n "$b" ] && { echo "${b#origin/}"; return; }
    for b in main master; do
        git show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null && { echo "$b"; return; }
    done
    echo main
}

staging_branch() { local b; b=$(cfg .staging.branch); echo "${b:-staging}"; }
staging_label()  { local b; b=$(cfg .staging.label);  echo "${b:-on-staging}"; }

cmd_url() {
    local site
    site=$(cfg .siteUrl)
    [ -z "$site" ] && die "siteUrl missing in $CONFIG (run: jira.sh init CLOUD_ID SITE_URL)"
    echo "${site%/}/browse/$1"
}

cmd_staging_keys() {
    local staging="${1:-origin/$(staging_branch)}" prod="${2:-origin/$(base_branch)}" ref
    git rev-parse --git-dir >/dev/null 2>&1 || die "Not inside a git repository"
    for ref in "$staging" "$prod"; do
        git rev-parse --verify -q "$ref" >/dev/null || die "Unknown ref: $ref"
    done
    {
        git branch -r --merged "$staging" --no-merged "$prod" --format='%(refname:short)'
        git log "$prod..$staging" --no-merges --format=%s
    } | tr '[:lower:]' '[:upper:]' | grep -oE "$KEY_RE" | while IFS= read -r k; do
        key_allowed "$k" && echo "$k"
    done | sort -u -t- -k1,1 -k2,2n
}

cmd_init() {
    local cloud="${1:-}" site="${2:-}"
    [[ "$cloud" =~ ^[A-Za-z0-9-]+$ ]] || die "Usage: jira.sh init CLOUD_ID SITE_URL (CLOUD_ID from getAccessibleAtlassianResources)"
    [[ "$site" =~ ^https://[A-Za-z0-9.-]+/?$ ]] || die "SITE_URL must look like https://example.atlassian.net"
    [ -e "$CONFIG" ] && die "$CONFIG exists already; edit it instead."
    mkdir -p "$ROOT" 2>/dev/null || die "jira: cannot write $ROOT"
    cat > "$CONFIG" <<EOF || die "jira: cannot write $CONFIG"
{
  "cloudId": "$cloud",
  "siteUrl": "${site%/}",
  "commentLanguage": "English",
  "worklogLanguage": "English",
  "baseBranch": "",
  "staging": { "branch": "staging", "label": "on-staging" },
  "excludePrefixes": [],
  "transitions": {
    "start": ["In Progress"],
    "close": ["Deployed", "Ready for testing", "In Review", "Resolved"],
    "done": ["Done"]
  }
}
EOF
    echo "Wrote $CONFIG"
}

cmd_config() {
    [ -r "$CONFIG" ] || die "Missing $CONFIG. Create it with: jira.sh init CLOUD_ID SITE_URL"
    local cl wl
    cl=$(cfg .commentLanguage); wl=$(cfg .worklogLanguage)
    echo "path=$CONFIG"
    echo "cloud_id=$(cfg .cloudId)"
    echo "site_url=$(cfg .siteUrl)"
    echo "comment_language=${cl:-English}"
    echo "worklog_language=${wl:-English}"
    echo "base_branch=$(base_branch)"
    echo "staging_branch=$(staging_branch)"
    echo "staging_label=$(staging_label)"
    echo "exclude_prefixes=$PREFIX_EXCLUDE"
    echo "ledger=$LEDGER"
    echo "timer=${TIMER_BIN:-missing}"
    echo "--- $CONFIG"
    cat "$CONFIG"
}

CMD="${1:-help}"; shift || true
case "$CMD" in
    key)          resolve_key "${1:-}" ;;
    session-name) need_timer; "$TIMER_BIN" session-name ;;
    figures)      k=$(resolve_key "${1:-}") || exit 1; cmd_figures "$k" ;;
    parse-time)   cmd_parse_time "$@" ;;
    mark-logged)  [ -n "${1:-}" ] || die "Usage: jira.sh mark-logged KEY SECONDS [WORKLOG_ID] [NOTE] [STARTED]"
                  k=$(resolve_key "$1") || exit 1; shift; cmd_mark_logged "$k" "$@" ;;
    logged)       k=""; if [ -n "${1:-}" ]; then k=$(resolve_key "$1") || exit 1; fi; cmd_logged "$k" ;;
    context)      k=$(resolve_key "${1:-}") || exit 1; cmd_context "$k" ;;
    day)          cmd_day "$@" ;;
    month)        cmd_month "$@" ;;
    url)          k=$(resolve_key "${1:-}") || exit 1; cmd_url "$k" ;;
    base-branch)  base_branch ;;
    staging-keys) cmd_staging_keys "$@" ;;
    init)         cmd_init "$@" ;;
    config)       cmd_config ;;
    help|-h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)            die "Unknown command: $CMD (try: jira.sh help)" ;;
esac
