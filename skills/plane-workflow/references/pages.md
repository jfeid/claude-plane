# Editing Plane project pages

Project pages (specs and other documents) cannot be edited with the API
token: the public API has no pages endpoint and the app API needs a browser
session. Edit them through Claude in Chrome, in the user's tab where they are
logged in to Plane, and only after the user agreed to the change (preview the
new text first, as for any other write).

The page body is a TipTap editor
(`document.querySelectorAll('.ProseMirror')[1].editor`); `setContent(html,
true)` replaces it and the change syncs. Convert markdown with
`pandoc -f gfm+hard_line_breaks -t html --wrap=none`, keep newlines inside
`<pre>`, check a page's `updated_at` before overwriting, and reload to
verify.

- **No blank lines inside `<pre>`**: `setContent` splits the code block at a
  blank line and the rest shows literal `&quot;`. Strip them first
  (`m.replace(/\n\s*\n/g, '\n')` on each `<pre>…</pre>`); check after reload
  that the code-block count and lengths match the source.
- **Checkboxes**: pandoc's `- [ ]` output is not a TipTap task list. Rewrite
  `<ul class="task-list">` to `<ul data-type="taskList">`, and
  `<li><label><input type="checkbox" />` (also `<li><p><label>…` for loose
  lists) to `<li data-type="taskItem" data-checked="false"><p>`, `</label>` to
  `</p>`. Tick one item without replacing the page: find the `taskItem` node
  with `state.doc.descendants` and dispatch `tr.setNodeMarkup(pos, undefined,
  {...attrs, checked: true})`.
- **Table widths**: `setContent` ignores widths in the HTML, so every cell
  gets the default `colwidth: [150]` and a 2-column table is 300 px wide.
  After `setContent`, set widths in one transaction: for each `table` node
  walk rows and cells and `tr.setNodeMarkup(cellPos, undefined, {...attrs,
  colwidth: [w]})`, with `w` per column in proportion to its average text
  length (min 50–70 px for `#`/ID columns). Total 720 px (the text width) for
  short tables, 960 px for tables with long text or 4 columns (they render as
  full-width blocks). Check after reload that the widths stayed.
- **Getting the HTML into the tab**: Chrome blocks the page from fetching
  `http://127.0.0.1` (local-network access), and typing 60 KB into
  `javascript_tool` is error-prone. Add a temporary `<input type="file">` to
  the page, fill it with `file_upload` (scratchpad file), read it with
  `files[0].text()`, compare its SHA-256 with the local file before
  `setContent`, then remove the input. Strip pandoc's leading `<h1>`: the
  page name is the title.
- **New page**: `POST /api/workspaces/<ws>/projects/<project_id>/pages/` from
  the logged-in tab with `{name, access: 0}` and the `X-CSRFToken` header
  (`csrftoken` cookie); then open it, fill it with `setContent`, and
  `plane.sh link KEY <page url> "Title"` on the work item.
