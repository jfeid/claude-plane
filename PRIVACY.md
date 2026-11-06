# Privacy

Plane Worklog (`plane-worklog`) is a Claude Code plugin by Giannis Feidaros
([jfeid](https://github.com/jfeid)). This is what it handles.

## Who sees your Plane data

The plugin has no server, account, telemetry, analytics or update check. The
developer receives nothing.

Its script (`plane.sh`) connects only to the Plane address in your settings
(`baseUrl`, or `apiUrl` when set), with your own API token, under the terms
of your Plane host (Plane Cloud or your own server). Through it, Claude reads
the work items you name, their comments, states, modules, relations and
links, your open work items, the workspace members' display names and your
own user id, and writes state changes, worklog comments, comments you
approved, and the titles, descriptions, new items, relations and links you
approved, as listed in the README.

What Claude reads (work item text, comments) and the reports are part of
your Claude Code conversation, which Claude Code sends to Anthropic under the
terms you use Claude Code with. The API token is not: the script reads it and
passes it to `curl` on standard input, never in the conversation, the
command line or the output.

## What it stores

On your computer only, under `~/.claude/plane/` (or `PLANE_HOME`):

- **Settings** (`config.json`): your Plane address, time zone, workspace
  slugs, project identifiers and ids, and your preferences (languages, base
  branch, states).
- **Token** (`token`, if you use the file): your Plane API token, written by
  you. The plugin only reads it. Alternatively it comes from the
  `PLANE_API_KEY` environment variable, or a `tokenFile` you name in the
  settings.
- **Ledger** (`logs/<project>.tsv`): for each worklog written through the
  plugin, the work item key, the seconds logged, the Plane comment id, when
  it was logged, the one-line note and the worklog's start time. The project
  name is the folder name of the git repository. `plane.sh forget` keeps a
  backup copy (`.bak-<time>`) next to it.

Notes and comments are what Claude drafts and you approve. If they contain a
customer's name or other personal data, the ledger keeps the note like any
other.

## What it reads

The files above; the timer's logs and the session's task through the
worklog-timer plugin's `timer.sh`; in the current git repository, the
branch, the commits and file names that mention a work item key, and file
names under `docs/` and `notes/`; the environment variables listed in the
README. It does not read Claude Code's session files, transcripts, history,
memory, settings or credentials.

The `/plane` command (a mod) reads nothing. It passes what you typed after
`/plane` to Claude as a prompt, with a note naming the skill to load.

## Keeping and deleting

The files are kept until you delete them.

- Delete a ledger line: edit `logs/<project>.tsv`.
- Delete everything: remove `~/.claude/plane/` (or your `PLANE_HOME`), and
  revoke the token in Plane.
- Uninstalling the plugin leaves the files in place.

Comments, worklog comments and states written to Plane stay in Plane; manage
them there.

## Contact

Giannis Feidaros, [jfeid on GitHub](https://github.com/jfeid),
info@maxweb.gr. Questions can also go to the
[GitHub issues](https://github.com/jfeid/claude-plane/issues).
