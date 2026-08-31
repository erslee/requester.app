# Requester

A native macOS HTTP client — projects of saved requests, `{{variable}}` templating,
post-response scripting for token chaining, and an append-only history of every send.

Built with SwiftUI and Swift 6 strict concurrency. **No third-party dependencies.**

---

## Features

**One project per window** — The app opens on a launcher listing the projects you
opened most recently, with the rest behind *All Projects*. Picking one opens it in its
own window, titled with the project's name; asking for the same project again focuses
the window it is already in rather than opening a second. **⌘N** makes a new project in
a new window, **⌘O** brings the launcher back.

**Requests** — Params, Headers, Body (raw / form / GraphQL), Auth (basic, bearer,
API key), and a post-response script, per request. Method, URL, and everything else
autosave shortly after you stop typing.

**Folders** — Requests can live in folders, nested as deep as you like. Importing a
Postman collection keeps its folder tree, and an OpenAPI document files each operation
under its first tag. Drag a request or a folder onto another folder to move it; the
project row is the drop target for "out of every folder". New Folder, Rename, and Delete
are on the right-click menu of a folder or the project. Where you file something is
yours: a re-sync never moves a request you have put somewhere.

**Favorites** — A tab strip sits at the top of the sidebar, Xcode-navigator style:
the folder icon is the project's tree, the bookmark icon is everything you have starred.
**Add to Favorites** is on the right-click menu of any request, and **⌘D** stars or
unstars whichever request is selected. The Favorites tab lists them flat — method, name,
and the folder each one is filed in — so it reads as a jump list rather than a second
tree; starred requests carry a small bookmark in the project tree too. Being a favorite
is stored on the request itself, so it travels with the data folder rather than staying
on one machine. The filter at the bottom narrows both tabs.

**Filter** — A filter field sits at the bottom of the sidebar, next to the new-request
button. Typing narrows the list to requests whose name, URL, or method match; Escape
clears it, **⇧⌘F** puts the cursor in it. The request you have open stays listed even
when it does not match, so the editor is never left pointing at a row that isn't there.
(**⌘F** stays find-in-response-body.)

**Global headers** — Headers set once on a project and sent with every request in it.
A request that sets the same header wins, whatever the casing; switching a header off in
a request sends it without that header at all. The request's Headers tab lists what it
inherits underneath its own, with overridden ones struck through. Global headers take
`{{variables}}` like any other field, and the requests themselves keep no copy of them.

**Variables** — Project-scoped `{{name}}` placeholders, substituted at send time into
the URL, params, headers, body, GraphQL query, and auth fields. Fields tint green when
every placeholder in them resolves and red when one doesn't, so a typo is visible
before you send rather than after.

**Post-response scripts** — JavaScript, run after the response arrives, to pull a token
out of one response and feed it to later requests:

```js
variables.token = response.json().access_token
```

Available to a script: `response.statusCode`, `response.headers`, `response.text`,
`response.json()`, `variables[...]`, and `console.log`.

**History** — Every send is recorded, including failures. Grouped by day, filterable by
text, method, and status code, scoped either to one request or to the whole project.
Opening an entry shows exactly what went over the wire — the resolved URL, the real
headers, the real body — while the saved request keeps its unresolved template.

**Import** — Paste a `curl` command into the URL field and it becomes a request. Bash
quoting is handled the way bash handles it, including `$'…'` ANSI-C strings (what
Chrome's *Copy as cURL* emits), so escapes and Unicode arrive intact. A JSON body
carrying a `query` is recognised as GraphQL and lands in the GraphQL tab.

Exported collection files (v2.1 collection JSON) import as a project, via
**File → Import Collection… (⇧⌘I)** or the sidebar button: requests, headers, query
params, auth, bodies, collection variables, and post-response test scripts, whose
host-specific API calls are translated to this app's. Anything that can't be
represented is reported in a summary rather than dropped silently.

**Response viewer** — JSON syntax highlighting, pretty/raw toggle, and find-in-body.
Minified responses are reformatted for reading, including ones truncated for display.

---

## Requirements

| | |
|---|---|
| macOS | 26.5 or later |
| Xcode | 26.6 |
| Swift | 6 language mode, strict concurrency |
| Dependencies | none |

## Build and run

```sh
xcodebuild -project requester.xcodeproj -scheme requester \
           -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/requester-*/Build/Products/Debug/Requester.app
```

Or open `requester.xcodeproj` in Xcode and press ⌘R.

## Tests

```sh
# Unit tests — fast, no window needed
xcodebuild -project requester.xcodeproj -scheme requester \
           -destination 'platform=macOS' -only-testing:requesterTests test

# Everything, including UI tests
xcodebuild -project requester.xcodeproj -scheme requester \
           -destination 'platform=macOS' test
```

104 unit tests (Swift Testing) covering the curl and collection importers, shell quoting,
variable resolution, request building, history storage and reconciliation, the JSON
formatter, syntax highlighting, auto-indent, the script runner, and the full
send→persist→script→variables pipeline against a stubbed network layer. Plus 5 UI
tests that drive the real app.

---

## Where your data lives

By default, in the app's own container — no permission prompt, nothing to configure:

```
~/Library/Containers/com.confjs.requester/Data/Library/Application Support/Requester/
```

**File → Reveal Data Folder in Finder** opens it. **Change Data Folder…** points the app
somewhere else — a synced folder, or a git repository — remembered across launches as a
security-scoped bookmark. **Use Default Data Folder** goes back.

Everything is plain files:

```
projects/<projectID>/project.json              project metadata + global headers
projects/<projectID>/requests/<requestID>.json  one file per request (folder is a
                                               path on the request, not a directory;
                                               so is the favorite flag)
variables/<projectID>.json                      project variables
history/<projectID>/YYYY-MM.jsonl               append-only, one line per send
history/<projectID>/blobs/<entryID>.body        response bodies too large to inline
```

History is append-only and never rewritten. A post-response script finishes *after* the
response has already been persisted, so its result is appended as a second line sharing
the same entry id; readers keep the last line written per id. A response body over
256 KB is spilled to its own blob file and trimmed inline, so re-reading the month's
history stays cheap — the viewer still shows the whole thing.

---

## Architecture

Layered, with each layer depending only on the one below it.

```
requesterApp.swift    App entry, data-folder resolution, menu commands

Views/                SwiftUI. Sidebar, request editor and its tabs, response
                      panel, history panel, import summary
UI/                   Presentation helpers: NSTextView-backed code editor with
                      syntax highlighting and auto-indent, method colours,
                      variable tinting

State/                @Observable models. AppModel (projects, selection),
                      EditorModel (draft, autosave, send), HistoryModel (scope,
                      filters), InterfaceStateStore (restored sidebar state)

Domain/               Pure logic, no UI: HTTPExecutor, VariableResolver,
                      HistoryService, ScriptRunner, CurlParser, ShellTokenizer,
                      JSONFormatter, RequestNaming, and the collection importer

Repositories/         CRUD over the storage backend: projects, requests,
                      variables, history (+ streaming history query)
Storage/              StorageBackend protocol, local-filesystem actor,
                      JSON coding, data-folder resolution
Models/               Codable, Sendable value types
```

`StorageBackend` is a protocol so a remote backend can be added without touching
repositories, domain, or views. `Domain/` has no SwiftUI import and is where nearly all
the tests point.

### Notes on the build settings

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — unannotated code is main-actor isolated,
  which suits SwiftUI. Models, domain, and storage are explicitly `nonisolated`.
- `PRODUCT_NAME = Requester` for the display name, with
  `PRODUCT_MODULE_NAME = requester` pinned so the Swift module name — and every
  `import requester` — is unaffected.
- Sandboxed. Four entitlements, and the app needs all of them: outgoing network
  connections, read-write access to user-selected files, app-scoped bookmarks (to
  remember a custom data folder across launches), and the sandbox itself.

---

## Known limitations

- **A hung script leaks one thread.** JavaScriptCore offers no public way to interrupt
  running code, so a script that never returns is timed out and reported, but its thread
  is abandoned until the app quits. The safety boundary is "don't freeze the app", not
  "defend against a malicious script".
- **Autosave is debounced by 700 ms.** Quitting within that window of your last keystroke
  loses that edit. There is no flush on termination.
- **Form file uploads are editable but not sent.** File fields are kept and shown; only
  the text fields are encoded into the body.
- **Collection import** flattens folders into request names, substitutes path variables
  with their values, and does not bring across pre-request or collection-level scripts,
  or OAuth2/digest/AWS auth. All of it is reported in the import summary.
- **History is read in full per query.** Month files are skipped by filename when a date
  range narrows it, but within a file every line is parsed. Fine at personal-tool volume.
- **UI tests are environment-sensitive.** The first launch of a freshly built binary
  sometimes comes up with no window at all; the tests relaunch once to work around it.
  If they fail immediately after a build, run them again.
