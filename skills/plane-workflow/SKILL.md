---
name: plane-workflow
description: Plane work item workflow with time tracking. Start or close a work item (read it, move its state, run the worklog timer, log the rounded time as a worklog comment, draft the closing comment), plus show, status, log, comment, move, done, mine, a full-day worklog report (day), a monthly billable-hours report (month) and editing work items after a preview. Use for /plane, or when the user asks to start or close a Plane work item, log time to Plane, or compare timer time with Plane worklogs.
argument-hint: "<start|close|show|status|log|day|month|comment|move|done|pause|resume|mine|setup|help> [KEY|URL|DATE|MM-YYYY] [...]"
user-invocable: false
allowed-tools: Bash(plane.sh key:*) Bash(plane.sh figures:*) Bash(plane.sh parse-time:*) Bash(plane.sh logged:*) Bash(plane.sh context:*) Bash(plane.sh day:*) Bash(plane.sh month:*) Bash(plane.sh base-branch:*) Bash(plane.sh config:*) Bash(plane.sh check:*) Bash(plane.sh issue:*) Bash(plane.sh comments:*) Bash(plane.sh worklogs:*) Bash(plane.sh worklog-days:*) Bash(plane.sh states:*) Bash(plane.sh ledger-check:*) Bash(plane.sh mine:*) Bash(plane.sh url:*) Bash(plane.sh modules:*) Bash(plane.sh relations:*) Bash(plane.sh links:*) Bash(plane.sh help:*) Bash(timer.sh:*)
---

# Plane work item workflow

Drive one Plane work item through the working day: read it, move it to In
Progress, run the timer, log the rounded time, move it to the "deployed"
state and post the closing comment. Works with Plane Cloud and self-hosted
Plane (Community Edition included).

Plane's API has no worklogs here, so a worklog is a **comment** on the work
item:

```
⏱ 1h 15m · started 2026-10-05 09:36 · Investigation and fix, tests, production deploy.
```

posted with `external_source=claude-timer` and a fixed `external_id`, so a
retry never creates a duplicate. The comments in Plane are the truth; the
ledger is a cache. Everything goes through this plugin's `plane.sh` (Plane
REST API, the token read only by the script) and the `timer.sh` tracker of
the worklog-timer plugin. Both are on the Bash tool's PATH while the plugins
are enabled; if the shell cannot find `plane.sh`, run
`${CLAUDE_PLUGIN_ROOT}/bin/plane.sh` instead.

## Arguments

$ARGUMENTS - `<action> [KEY|URL] [extra...]`

`KEY` is optional everywhere: when omitted it is the session's task (the
session's name, `/rename ABC-12`, or the last task named with the timer), so
every `/plane` call in that session targets ABC-12. A Plane browse URL is
accepted in place of the key. Only keys whose prefix is a project in the
config's `workspaces` are Plane keys; any other key is refused.

**Workspaces**: the prefix selects the workspace, so every action works
across workspaces without a switch; a prefix belongs to one workspace only.
`mine`, `day`, `month` and `check` cover every workspace. Relations and
parents stay within one workspace. Time is tracked per repository (timer log
and ledger), whichever workspace the key is in.

- `/plane start [KEY] [--branch|--base]` - read the work item and its comments, ask whether to work on a `KEY` branch or on the base branch and switch to it, move to In Progress, start the timer, brief the user
- `/plane close [KEY]` - stop the timer, log the rounded time, move to the "deployed" state, preview the closing comment
- `/plane show [KEY]` - re-read the work item without changing anything
- `/plane status [KEY]` - one-screen state: Plane state, timer, logged vs unlogged time
- `/plane log [KEY] [1h 30m]` - log work now without closing (timer figure, or the given duration)
- `/plane day [DATE] [--here] [--scan]` - full-day worklog report: timer vs Plane worklogs, then log the remainder in one batch after a preview
- `/plane month [MM-YYYY] [--here] [--scan]` - month report in billable hours, timer vs Plane worklogs (read-only)
- `/plane comment [KEY] <notes>` - draft a comment from the notes, preview, post on confirmation
- `/plane move [KEY] <state>` - move to any state of the project
- `/plane done [KEY]` - move to Done (after the reporter verified)
- `/plane pause [KEY]` / `/plane resume [KEY]` - pause or resume the timer
- `/plane mine` - my open work items
- `/plane setup` - create or show the settings
- `/plane help` - this list

No action given: run `status` when a key resolves, otherwise print the action list.

## Setup (every action)

1. Parse `$ARGUMENTS`: first word is the action, the next word is the key
   only if it looks like `ABC-123` or a Plane URL; everything else is extra
   input. Aliases: `open`/`begin` → `start`, `finish`/`stop` → `close`,
   `today`/`report` → `day`, `monthly` → `month`, `transition` → `move`,
   `--master`/`--main` → `--base`.
2. Resolve the key (skip for `day`, `month`, `mine`, `setup`, `help`, and for
   `pause`/`resume` without an argument), from inside the project so the
   timer log and the ledger match the repository: `plane.sh key [KEY]`.
   Non-zero exit: no key in the argument or the session's task, or a key
   whose prefix is not a Plane project: report the message and stop (ask
   for the key in the first case). When the key came from the argument and
   the session has no task, end the reply with
   `Tip: /rename KEY so later /plane calls find it.`
3. Load the settings: `plane.sh config` prints `base_url`,
   `comment_language`, `worklog_language`, `base_branch`, `prefixes`, the
   token source per workspace (never the token) and the config file. When it
   exits with "Missing", or the token shows `MISSING`, do `setup` first.

Independent calls go in the same response. Never read, print or ask for the
token; only `plane.sh` reads it.

| Need | Call |
|---|---|
| Work item fields + description | `plane.sh issue KEY` (key=value lines, then the description text) |
| Comments (worklogs folded) | `plane.sh comments KEY` |
| Worklogs of one item | `plane.sh worklogs KEY [FROM [TO]]` → TSV key, comment_id, started_epoch, seconds, mine, source, note |
| My worklogs per day | `plane.sh worklog-days FROM TO [--scan]` → TSV date, key, seconds, count |
| Timer figures | `plane.sh figures KEY` → `rounded_seconds`, `time_spent`, `started` |
| Log work | `plane.sh log-work KEY SECONDS STARTED "note"` → posts the comment **and** records the ledger row; prints `comment_id`, `existing` (1 = the same worklog was already there) |
| Move state | `plane.sh move KEY start\|close\|done\|<state name>` → `old → new`, `already in`, or exit 3 with the state list |
| States | `plane.sh states KEY`; add one: `plane.sh add-state PREFIX Deployed started` (skipped if present) |
| Comment | `plane.sh comment KEY` with markdown on stdin (heredoc) |
| Ledger vs Plane | `plane.sh ledger-check [KEY]` → TSV key, comment_id, ledger_s, plane_s, ok/changed/missing |
| Drop a stale ledger row | `plane.sh forget COMMENT_ID` (only after the user agrees) |
| Local reports | `plane.sh day …`, `plane.sh month …` (timer and ledger, Plane keys only) |
| My open items | `plane.sh mine` |
| Browse URL | `plane.sh url KEY` |
| Commits for a closing note | `plane.sh context KEY` |
| Change title / description | `plane.sh update KEY [--title "T"] [--description]` with markdown on stdin (`--html` for raw HTML) |
| New work item | `plane.sh create PREFIX --title "T" [--parent KEY] [--module NAME] [--state NAME] [--priority P]`, description on stdin → `key=`, `id=` |
| Modules | `plane.sh modules PREFIX` → TSV id, name (`--module` matches a name or its start) |
| Relations | `plane.sh relations KEY` → TSV type, key; `plane.sh relate KEY blocked_by\|blocking\|relates_to\|duplicate OTHER...` |
| Links | `plane.sh links KEY` → TSV id, title, url; `plane.sh link KEY URL ["Title"]` (skips a URL already linked) |
| Raw read | `plane.sh get /workspaces/<ws>/...` (JSON, GET only, for inspection) |

Markdown for comments, descriptions and new items: paragraphs, `- `
bullets, `**bold**`, `*italic*`, `` `code` ``. Write it with a quoted heredoc
so nothing is expanded:

```bash
plane.sh comment ABC-12 <<'EOF'
**Fix**

...
EOF
```

Project pages (specs and other documents) are not in the public API. To edit
one, read [references/pages.md](references/pages.md) first.

### Target states

`start`, `close` and `done` use the preference lists in the config
(`transitions.start`, `.close`, `.done`; a workspace can override any of them
in `workspaces.<slug>.transitions`): first exact name match
(case-insensitive), else the first state starting with the first preference
("Deployed" matches "Deployed for testing"). Without lists: `In Progress`;
`Deployed`, `Ready for testing`, `In Review`; `Done`. `move` exits 3 with the
list when nothing matches: show it and ask which state to use. When the item
is already in the target state the script says so and nothing changes. Never
move to Done except through `done` or an explicit `move`.

## setup

1. `plane.sh config`. When it prints the settings and every workspace has a
   token, run `plane.sh check`, show the result and say which file to edit
   (path in the first line) for the languages, the state lists and the base
   branch. Stop.
2. When it exits with "Missing": ask for the Plane address (AskUserQuestion,
   options `Plane Cloud (https://app.plane.so)` and `Self-hosted`; for
   self-hosted, the address they type) and run `plane.sh init BASE_URL`.
3. Token: when `plane.sh config` shows `MISSING` for the token, tell the user
   to create a personal access token in Plane (profile settings, Personal
   Access Tokens) and save it themselves, without pasting it into the
   conversation, either in the file `plane.sh config` names (one line,
   `chmod 600`) or in the `PLANE_API_KEY` environment variable. Wait until
   they say it is done.
4. Workspaces: ask for the workspace slug (the first part of the path in
   Plane's URLs, `https://app.plane.so/<slug>/...`), then
   `plane.sh add-workspace SLUG` (every project) or
   `plane.sh add-workspace SLUG ABC DEF` (only those project identifiers).
   Repeat for each workspace, then `plane.sh check`.
5. Show `plane.sh config` and ask only about what they want to change
   (comment and worklog language, base branch, state lists).

Any other action that finds no config runs these steps first, then goes on.

## start

1. Setup.
2. In parallel: `plane.sh issue KEY`, `plane.sh comments KEY`,
   `timer.sh list` (to know whether the key already has time).
3. Attachments are not fetched; if the description refers to one, say so in
   the briefing.
4. `plane.sh move KEY start`.
5. `timer.sh on KEY` (resumes if paused).
6. Branch. `BASE` is `base_branch` from `plane.sh config`. Skip the question
   when the extra input has `--branch` or `--base`, when the current branch
   is already `KEY`, or when the folder is not a git repository. Otherwise
   ask with AskUserQuestion, header `Branch`, question `Work on a KEY branch
   or on BASE?`, options `Branch KEY` (description: new branch from the
   latest origin/BASE) and `BASE` (description: commit straight to BASE).
   Then, in the project repository:
   - First `git status --porcelain --untracked-files=no`. With uncommitted
     changes do not switch anything: say so in the briefing and leave the
     choice for the user to apply.
   - `git fetch origin BASE`.
   - **Branch**: if `KEY` exists locally, `git switch KEY`; else if
     `git ls-remote --heads origin KEY` finds it, `git switch --track
     origin/KEY`; else `git switch --no-track -c KEY origin/BASE`. Do not
     push now; the branch is pushed with the first commit
     (`git push -u origin KEY`).
   - **BASE**: `git switch BASE`, then `git merge --ff-only origin/BASE`.
     When it cannot fast-forward, say so and leave it.
   A git failure is not fatal: report it in the briefing and continue. When
   a sandbox blocks a git command, say so; the user decides whether to run
   it outside the sandbox.
7. Reply with the briefing and stop. Do not investigate beyond a couple of
   greps or file reads needed to name the likely code area, and do not
   change code: the user directs the work after the briefing.

```
**KEY - title**
priority · assignees · old state → In Progress · <url>

**Request** - what is asked or what breaks, in 2-5 sentences. Error text,
identifiers, dates and amounts verbatim in a code block.

**Comments (N)** - one bullet per comment: date, author, gist (worklog
comments as one line: "worklogs: 2h 30m in 3 entries"). "None" when empty.

**Timer** - `KEY started`, or resumed with the total tracked so far.

**Branch** - `KEY` (new from origin/BASE @ <short sha>, existing, or
tracking origin/KEY) or `BASE` (up to date with origin/BASE @ <short sha>),
or why nothing was switched.

**Understanding** - the problem in one or two sentences, the likely code
area, acceptance criteria as you read them, open questions.
```

If the assignees are someone else or empty, say so in the header line; do
not change them unless asked.

## close

1. Setup.
2. `timer.sh off KEY` ("not active" is fine; the recorded total is used).
3. `plane.sh figures KEY`. It subtracts time already logged through this
   workflow (the ledger) and rounds the remainder UP to the quarter hour.
4. When `rounded_seconds` is 0, say there is nothing new to log. Otherwise
   (invoking `close` is the request): `plane.sh log-work KEY
   <rounded_seconds> "<started>" "<note>"` with a one-line note in
   `worklog_language` naming only the phases that happened, e.g.
   `Investigation, fix (IBAN matching), tests, production deploy.`
5. `plane.sh move KEY close`.
6. Draft the closing comment (style below) from this session's work; in a
   fresh session first run `plane.sh context KEY` (branch, commits
   mentioning the key, files touched, task docs under `docs/` and `notes/`)
   and re-read the item; if the facts are thin, ask before drafting.
7. Report, then show the comment in a fenced block and ask whether to post
   it as is, edit it, or skip it. Post with `plane.sh comment` only after an
   explicit yes; an edited text is a new preview.

```
**KEY closed**
| Step | Result |
|---|---|
| Timer | stopped · 1h 09m tracked · 1h 15m rounded |
| Worklog | 1h 15m logged · started 2026-10-05 11:24 · comment <first 8 chars of id> |
| State | In Progress → Deployed |
| Comment | waiting for confirmation |
<url>
```

When `existing=1`, the worklog was already in Plane (a retry); say so in the
Worklog row.

## day

Read-only until the user answers the final question.

1. Setup steps 1 and 3 only; no key. Parse the extra input: `--here`
   (current repository's logs only), `--scan` (check every work item in
   Plane, not only keys with timer or ledger rows: finds worklogs typed by
   hand on items never timed; slower, and Plane allows about 60 requests a
   minute), anything else is the date (default `today`, also `yesterday`,
   `YYYY-MM-DD`, `"last friday"`).
2. In parallel: `plane.sh day [DATE] [--here]` (local figures: header,
   table, one `[KEY]` block per item with `unlogged_rounded_seconds`,
   `time_spent`, `started`, the timeline and the ledger rows) and
   `plane.sh worklog-days DATE DATE [--scan]` (my worklog comments filed
   under that day, per key). Then `plane.sh issue KEY` for each key from
   either source, for title and state (only the `title=` and `state=` lines
   are needed).
3. Report:

   ```
   **Day report - Monday 2026-10-05** (all projects · generated 17:46)
   | Key | Title | State | Tracked | Rounded | Plane | To log |
   |---|---|---|---|---|---|---|
   | ABC-12 | Title cut at 50 chars | In Progress | 1h 32m | 1h 45m | - | 1h 45m |
   | ABC-9 | ... | Deployed | 20m | 30m | 30m | - |
   | ABC-4 | logged by hand, no timer | Done | - | - | 45m | - |
   | **Total** | | | 1h 52m | 2h 15m | 1h 15m | 1h 45m |

   Timeline: 09:36-11:08 ABC-12 · 12:32-12:52 ABC-9 · ...
   ```

   Tracked/Rounded from the timer for that day; Plane = my worklog comments
   started that day; To log = `unlogged_rounded_seconds` (the whole
   remainder, which can include earlier days; say so when it differs from
   Rounded). Rows sorted by first touch, hand-logged rows last.

   **Checks**, only what applies:
   - a running or paused timer;
   - a key where the ledger holds more for the day than Plane: run
     `plane.sh ledger-check KEY`; a `missing` row means the comment was
     deleted, `changed` that it was edited. Plane is the truth: offer
     `plane.sh forget COMMENT_ID` for the stale row;
   - a key where Plane holds more than the ledger (typed by hand in the UI):
     the remainder may be too high; offer
     `plane.sh mark-logged KEY SECONDS COMMENT_ID "logged by hand" STARTED`
     to align the ledger before logging;
   - a day total below the tracked wall clock by more than 30 minutes once
     everything is logged.
4. Nothing to log: `Nothing left to log for DATE.` Otherwise preview:

   ```
   | Key | Time | Started | Worklog note |
   |---|---|---|---|
   | ABC-12 | 1h 45m | 2026-10-05 09:36 | Investigation and fix of ... |
   ```

   Notes are drafted as in `close`; for a key this session did not touch use
   `plane.sh context KEY`; when still thin put `?` and ask. Then ask:
   `Reply "log all", "log KEY,KEY" or "skip".` and do nothing until the
   answer is one of those; an edited note is a new preview.
5. On `log ...`: `plane.sh log-work KEY <unlogged_rounded_seconds>
   "<started>" "<note>"` per chosen key. Timers and states stay as they are.
   Report key, time, comment id and the new day total. A failure stops the
   batch; say which keys were written.

## month

`day` summed over a month. Read-only; remainders are logged with
`/plane day DATE`.

1. Setup steps 1 and 3 only; no key. Extra input: `--here`, `--scan`, the
   month as `MM-YYYY` (also `M-YYYY`, `YYYY-MM`, `last`); default the
   current month.
2. In parallel: `plane.sh month [MM-YYYY] [--here]` (a `key=value` header
   with `first_day`, `last_day`, `billable_seconds`, `billable_hours`, …, a
   `--- days` and a `--- tickets` table; BILLABLE is per item per day rounded
   up to the quarter and summed) and `plane.sh worklog-days <first_day>
   <last_day> [--scan]`. Titles and states via `plane.sh issue` (top 25 keys
   only). A bad month exits non-zero with a message; report it and stop.
3. Report:

   ```
   **Month report - October 2026** (all projects · 16 days · generated 15:00)

   **Billable: 107h 00m (107.00 h)** · tracked 98h 51m · in Plane 103h 00m (103.00 h) · to log 5h 45m

   | Date | Day | Items | Tracked | Billable | Plane | Diff |
   |---|---|---|---|---|---|---|
   | 2026-10-01 | Thu | 2 | 4h 35m | 5h 00m | 4h 45m | -15m |
   | **Total** | | 43 | 98h 51m | 107h 00m | 103h 00m | -4h 00m |

   | Key | Title | State | Days | Tracked | Billable | Plane | To log |
   |---|---|---|---|---|---|---|---|
   | ABC-12 | Title cut at 50 chars | In Progress | 3 | 12h 57m | 13h 15m | 13h 00m | - |
   | ABC-4 | logged by hand, no timer | Done | - | - | - | 45m | - |
   | **Total** | | | | 98h 51m | 107h 00m | 103h 00m | 5h 45m |
   ```

   Plane is the sum of my worklog comments started in the month (per day,
   per key). Diff is Plane minus Billable, `-` when equal. To log is the
   UNLOGGED column (the whole remainder, which can include other months).
   Days with neither timer nor Plane time are left out. With more than 25
   items, list the top 25 by Billable and fold the rest into one `+N more`
   row, so the totals stay exact.

   **Checks**, only what applies: a running or paused timer; days where
   Plane is below Billable by 15 minutes or more (one line with the dates,
   and `Run /plane day DATE to log the remainder.`); days or keys where
   Plane is above Billable; a key where the ledger holds more than Plane
   (run `plane.sh ledger-check KEY`); an item with less than a minute
   tracked on a day, which still bills a quarter for that day.
4. End with `October 2026: 12.50 billable hours over 6 days.` Do not offer
   to log from here.

## Other actions

- `show` - `issue` + `comments`, briefing without state change, timer or
  branch. Header shows the current state only.
- `status` - `plane.sh issue KEY` and `plane.sh figures KEY`; one small
  table: state, assignees, updated, timer state, tracked, logged, unlogged
  (rounded), URL. Add `plane.sh ledger-check KEY` when logged > 0 and flag
  any row that is not `ok`.
- `log [time]` - `plane.sh figures KEY`; the given duration
  (`plane.sh parse-time "1h 30m"`) or `rounded_seconds`. Zero: nothing to
  log. Otherwise `plane.sh log-work` as in `close` step 4, with `started`
  from the figures. The timer keeps its state.
- `comment <notes>` - draft (from the notes or the session), preview, post on
  an explicit yes.
- `move <state>` - `plane.sh move KEY "<state>"`; exit 3: show the states and
  ask.
- `done` - `plane.sh move KEY done`. Warn first when the timer is running or
  has unlogged time (suggest `/plane close` or `/plane log`).
- `pause` / `resume` - with an argument, resolve it through
  `plane.sh key ARG` and run `timer.sh pause KEY` / `resume KEY`. Without
  one, run `plane.sh key` for the session's item: when it gives a key whose
  timer (`timer.sh list`) is running (for `pause`) or paused (for `resume`),
  run `timer.sh pause KEY` / `resume KEY`. Otherwise run the timer with no
  task; on exit 2 ask which of the listed tasks to act on (AskUserQuestion,
  one option per task plus `All` when there are several), then re-run with
  the chosen keys or `--all`. Echo the timer output.
- `mine` - `plane.sh mine`; show it as a table (updated, key, state, title);
  mark the session's key with `*`.
- `help` - print the action list from the Arguments section.

## Editing the plan

Not an action of its own: used when the user asks to restructure or update
work items (for example after a spec change). Descriptions follow the style
of the project's existing items.

1. Read the affected items (`issue`, `relations`, `modules`) and compare them
   with the source (spec, plan, session findings).
2. Draft every change into the scratchpad, one file per item (`KEY.md`,
   `NEW-<slug>.md`), and preview: title changes, new items in full with
   parent, module, state, priority and relations, and per changed item what
   changes.
3. After an explicit yes: `create` first (it prints the new keys), then
   `relate`, then `update` from the same files, so what is applied is what
   was previewed. Spot-check with `issue` and `relations`.
4. Report the new keys, the changed keys and anything left as it was.

## Comment style

Comments are written in `comment_language` (from `plane.sh config`), plain
and operator style: short sentences, facts, no greeting, sign-off, emoji,
praise or marketing words. Written for the reporter, who is usually not a
developer: behaviour, not classes or files. Under about 15 lines; bullets
only for lists. The closing comment starts directly with the heading;
translate the headings into `comment_language`:

```
**Fix**          (or **Implementation** for a new feature or change)

<What changed, in plain sentences or bullets.>

<What the user sees now, what to check, whether they need to do anything,
where it was deployed (staging / production).>
```

State only what happened. Never post without a preview and an explicit yes.

## Rules

- **Writes to Plane** only through the steps above: state moves in `start`,
  `close`, `move`, `done`; worklog comments in `close`, `log`, and `day`
  after the user picks keys; other comments after a confirmed preview;
  titles, descriptions, new items, relations and links only through
  *Editing the plan*, after a confirmed preview. Nothing is deleted; other
  people's comments and worklog comments are never edited or deleted.
- **No scope creep**: assignees, priority, labels, cycles and modules stay as
  they are unless the user asks.
- **Language**: comments in `comment_language`, worklog notes in
  `worklog_language`, replies to the user in the language they write in.
- **Timer**: the worklog-timer rules apply: round UP to the quarter,
  reviewing counts, re-read the total right before logging. `log-work`
  always records the ledger row; never call `mark-logged` after it.
- **Ledger fixes** (`forget`, `mark-logged` by hand) only after the user
  agrees in that message.
- **Failures**: `plane.sh` retries once on 429/5xx. If a call still fails,
  stop and say what already changed (timer, state, worklog), so the user can
  finish by hand. HTTP 401/403: the token is wrong or lacks access to that
  workspace.
- **Token**: never `cat`, print, pass or ask for the token; only `plane.sh`
  reads it.
- **Secrets**: descriptions and comments may contain credentials or personal
  data; quote only what the task needs.
- **Session name**: do not look for the session's name yourself and never
  read transcripts for it; `plane.sh key` gets the session's task from
  `timer.sh`.

## Files

- `/plane` - this plugin's mod (`hooks/register.ts`) hands the typed
  arguments to this skill
- `plane.sh` - this plugin's helper; `plane.sh help` lists every command
- `~/.claude/plane/config.json` - `baseUrl`, `apiUrl`, `timezone`,
  `commentLanguage`, `worklogLanguage`, `baseBranch`, `transitions`,
  `workspaces.<slug>.projects` (prefix → project id), per workspace optional
  `transitions` and `tokenFile` (`PLANE_HOME` moves the folder)
- `~/.claude/plane/token` - API token (600), or `PLANE_API_KEY`
- `~/.claude/plane/logs/<project>.tsv` - worklog ledger (key, seconds,
  comment id, epoch, timestamp, note, started epoch)
- `~/.claude/timer/logs/<project>.tsv` - timer log written by `timer.sh`
