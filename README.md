# ![Plane Worklog icon](docs/icon-40.png) Claude Code Plane workflow

[![test](https://github.com/jfeid/claude-plane/actions/workflows/test.yml/badge.svg)](https://github.com/jfeid/claude-plane/actions/workflows/test.yml)

Plane Worklog (`plane-worklog`) is a Claude Code plugin that takes one
[Plane](https://plane.so) work item through the working day: read it with its
comments, move it to In Progress, run a timer, log the time rounded up to the
quarter hour, move it on and draft the closing comment. Day and month reports
compare what the timer tracked with what Plane holds, and log the remainder
after you approve a preview.

It works with Plane Cloud and with self-hosted Plane, Community Edition
included. Plane's API has no worklogs there, so a worklog is a comment on the
work item:

```
⏱ 1h 15m · started 2026-10-05 09:36 · Investigation and fix, tests, production deploy.
```

It is posted with a fixed external id, so a retry never creates a duplicate,
and the reports read these comments back, also the ones you type by hand in
the same form.

It builds on [Worklog Timer](https://github.com/jfeid/claude-timer)
(`worklog-timer`), the per-task timer, which is installed with this plugin as
a dependency. The Jira counterpart is
[Jira Worklog](https://github.com/jfeid/claude-jira); both can be installed
side by side, each taking the keys of its own tracker.

This plugin is not made by or affiliated with Plane.

## Install

At the prompt of a Claude Code terminal session:

```
/plugin marketplace add jfeid/claude-timer
/plugin install plane-worklog --marketplace jfeid/claude-plane
```

The first line makes the timer's marketplace known, so the `worklog-timer`
dependency can install. Pick user scope to load it in every session. Then run
`/plane setup` once. It asks for your Plane address (Plane Cloud or your own)
and your workspace, and writes the settings file. The API token you create
yourself in Plane (profile settings, Personal Access Tokens) and save in
`~/.claude/plane/token` (one line, `chmod 600`) or in the `PLANE_API_KEY`
environment variable. Do not paste it into the conversation.

## Use

```
/plane start ABC-12            read the work item, pick a branch, In Progress, start the timer, brief me
/plane close                   stop the timer, log the rounded time, move on, preview the closing comment
/plane show | status           re-read the item / Plane state, timer, logged and unlogged time
/plane log [1h 30m]            log work now without closing (timer remainder, or the given time)
/plane day [DATE] [--here] [--scan]
                               one day: timer vs Plane worklogs per item, then log the rest after a preview
/plane month [MM-YYYY] [--here] [--scan]
                               billable hours per day and per item against Plane (read-only)
/plane comment <notes>         draft a comment, preview, post on yes
/plane move <state>            move to any state of the project
/plane done                    move to Done
/plane pause | resume          the item's timer
/plane mine                    my open work items, across workspaces
/plane setup | help
```

`/plane` hands what you typed to Claude, which loads the plugin's skill
(`plane-workflow`) and runs the action. You can also ask in plain words
("close the work item and log the time", "what is left to log for
yesterday?", "split ABC-12 into two items under the same parent"), and the
same skill runs.

**The key** is optional: without one, `/plane` uses the session's task from
the timer, which is the session's name or the last task you named with the
timer. Name the session after the work item and every call finds it:

```
/rename ABC-12             or start the session with: claude -n ABC-12
/plane start               reads and starts ABC-12
/plane close               closes ABC-12
```

A Plane browse URL works in place of the key. Only keys whose prefix is a
project in your settings are taken; with several workspaces, the prefix picks
the workspace.

**What it writes to Plane**, and when:

| Action | Writes |
|---|---|
| `start` | state → In Progress |
| `close` | worklog comment, state → the "deployed" state; the closing comment only after you say yes to the preview |
| `log` | worklog comment |
| `day` | worklog comments for the items you pick from the preview |
| `move`, `done` | state |
| `comment` | the comment, after you say yes to the preview |
| editing the plan (asked in plain words) | titles, descriptions, new items, relations, links, after you say yes to the preview |

`show`, `status`, `month` and `mine` only read. Nothing is deleted, other
people's comments are never edited, and assignees, priority, labels, cycles
and modules are left as they are unless you ask.

**Rounding.** Each worklog is the timer's unlogged time rounded up to the
quarter hour. A ledger (below) remembers what was logged, so the next `log`
or `close` takes only the remainder. The comments in Plane are the truth:
`day` and `month` compare the ledger with them and point out worklogs deleted
or typed by hand.

**Branches.** `start` asks whether to work on a `ABC-12` branch made from the
base branch or on the base branch itself, and switches to it when the working
tree is clean. It never pushes.

### Settings

`/plane setup` writes `~/.claude/plane/config.json`:

```json
{
  "baseUrl": "https://plane.example.com",
  "apiUrl": "",
  "timezone": "",
  "commentLanguage": "English",
  "worklogLanguage": "English",
  "baseBranch": "",
  "transitions": {
    "start": ["In Progress"],
    "close": ["Deployed", "Ready for testing", "In Review"],
    "done": ["Done"]
  },
  "workspaces": {
    "acme": { "projects": { "ABC": "3f1c…", "OPS": "9a2e…" } }
  }
}
```

| Setting | Effect |
|---|---|
| `baseUrl` | the address you open Plane at; browse links are built from it |
| `apiUrl` | the API address when it differs (`https://api.plane.so` for Plane Cloud); empty: `baseUrl` |
| `timezone` | time zone for dates in reports and worklogs, e.g. `Europe/Athens`; empty: the system's |
| `commentLanguage` | language of the comments drafted for the work item |
| `worklogLanguage` | language of the one-line worklog notes |
| `baseBranch` | branch new work starts from; empty: origin's default branch |
| `transitions` | target states, in order of preference; the first one the project has wins, and "Deployed" also matches "Deployed for testing" |
| `workspaces` | per workspace slug, its projects (identifier → id), added with `plane.sh add-workspace`; optional `transitions` and `tokenFile` per workspace |

A workspace that needs another token gets `"tokenFile": "~/.claude/plane/token-acme"`.

Environment variables: `PLANE_HOME` (default `~/.claude/plane`) moves the
folder; `PLANE_API_KEY` holds the token when there is no token file;
`TIMER_HOME`, `TIMER_PROJECT` and `TIMER_QUARTER` are the timer's and are
honoured here too.

### The script

The plugin puts `plane.sh` on the Bash tool's PATH. It does the Plane calls
and works out the figures:

```
plane.sh issue ABC-12            fields and description
plane.sh figures ABC-12          tracked, logged, unlogged, rounded time and start
plane.sh log-work ABC-12 4500 "2026-10-05 09:36" "Fix and tests."
plane.sh day yesterday           one day across projects, with ready-made worklog values
plane.sh worklog-days 2026-10-01 2026-10-31
plane.sh month 10-2026           billable hours per day and per item
plane.sh check                   token, user and projects in every workspace
plane.sh help                    every command
```

The skill lets Claude run the read-only commands without a permission prompt;
commands that write to Plane ask first. To allow every command outside the
skill too, add `"Bash(plane.sh:*)"` to `permissions.allow` in
`~/.claude/settings.json`.

## Data

The plugin has no server, account, telemetry or update check. `plane.sh`
connects only to the Plane address in your settings, with your token. See
[PRIVACY.md](PRIVACY.md).

What it writes on your computer:

- `~/.claude/plane/config.json`: your Plane address, workspaces, project ids
  and the settings above.
- `~/.claude/plane/token`: your API token, if you choose the file over the
  environment variable. You write it; the plugin only reads it.
- `~/.claude/plane/logs/<project>.tsv`: the ledger, one line per worklog
  written through `/plane`: key, seconds, comment id, when it was logged, the
  note, and the worklog's start. Plain text; it can be edited by hand.
  `plane.sh forget` keeps a `.bak-<time>` copy next to it.

What it reads besides those: the timer's logs and session task through
`timer.sh`; in the current git repository, the branch, commits and file names
that mention the key, and file names under `docs/` and `notes/`. It does not
read Claude Code's session files, transcripts, history, memory, settings or
credentials.

Work item content (description, comments) and the reports are shown in your
conversation, and Claude Code sends the conversation to Anthropic, as with
anything Claude reads. The token is never shown: the script passes it to
`curl` on standard input, so it is not in the conversation or the process
list.

## What the mod does

The `/plane` command comes from `hooks/register.ts`, a mod. It sends nothing
over the network and runs no programs. In detail:

- **What it registers:** the slash command `/plane`. A plugin skill would
  show as `/plane-worklog:<name>`, so the skill is named `plane-workflow` and
  hidden from the `/` menu, and the mod provides the plain name.
- **What it gives Claude:** for `/plane <args>`, a prompt `plane <args>`
  submitted as your own words, and a note only Claude reads, naming the
  skill to load and the arguments. Nothing else.
- **What it reads:** nothing: no files, environment variables or settings.
- **Hooks:** `session.start` registers the command; `command.run` answers
  `/plane` only. No hook makes or changes a permission decision.

## Requirements

- Claude Code 2.1.287 or later in the terminal (2.1.286 in the Desktop
  app's Code tab) for `/plane`, which is a mod. On versions without mods, ask
  Claude in plain words and the skill runs the same actions. claude.ai and
  Cowork do not install plugins with a `bin/` folder.
- The `worklog-timer` plugin, version 0.5 or later (installed as a
  dependency).
- A Plane workspace (Plane Cloud or self-hosted) and a personal access token
  with access to the projects you use.
- bash (3.2 or later), `curl`, `jq` and the usual shell tools. On macOS:
  `brew install jq`. On Windows, [Git for Windows](https://gitforwindows.org/),
  as for the timer, plus jq.

Sandbox: with Claude Code's sandbox turned on, Claude's Bash tool cannot
write outside the project folder or reach hosts it was not given. Allow the
plugin's folders in `~/.claude/settings.json`:

```json
{
  "sandbox": {
    "filesystem": {
      "allowWrite": ["~/.claude/plane", "~/.claude/timer"]
    }
  }
}
```

and allow your Plane host for the sandbox's network (`/sandbox`), or the
first call to it is blocked.

`git fetch` and branch switches in `start` may also need the sandbox's
network or `.git/config` access; Claude says when a command was blocked.

Dates: with GNU `date` (Linux, Git Bash, or `gdate` from
`brew install coreutils` on macOS) `day` takes anything `date -d` reads,
such as `"last friday"`. With the macOS `date` it takes `today`,
`yesterday`, `tomorrow` or `YYYY-MM-DD`.

Used daily on Linux with self-hosted Plane Community Edition. CI runs the
script's tests against a fake Plane API on Linux, macOS and Windows (Git
Bash). Reports from other setups, Plane Cloud included, are welcome in the
issues.

## Try it with sample data

`tests/sample-data.sh` writes made-up timers and one logged worklog into a
folder of its own, without touching your real files (it needs the timer's
`timer.sh`):

```
bash tests/sample-data.sh /tmp/plane-sample
export TIMER_HOME=/tmp/plane-sample PLANE_HOME=/tmp/plane-sample/plane TIMER_PROJECT=acme-shop
bin/plane.sh figures ABC-118       5h 50m tracked, 3h 00m logged, 3h to log
bin/plane.sh month                 about 11.75 billable hours, 3h logged
```

The Plane steps need a Plane workspace you can write to; a free Plane Cloud
workspace works for trying it.

## Develop

```
claude --plugin-dir . --plugin-dir ../claude-timer   load both for one session
claude plugin validate --strict .
claude plugin test .               the mod's tests
bash tests/plane-cli.sh            plane.sh end to end against a fake Plane API
                                   (needs jq and ../claude-timer or TIMER_BIN)
```

`lib/figures.sh` is a copy of `bin/jira.sh` from
[claude-jira](https://github.com/jfeid/claude-jira), so both plugins compute
the figures the same way; a fix there is copied here.

## Security and support

Questions and bugs: [GitHub issues](https://github.com/jfeid/claude-plane/issues).
Security reports: see [SECURITY.md](SECURITY.md).

## License

MIT
