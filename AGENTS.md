# Transcripts for Omarchy

## Purpose and original intent

This project is a native Omarchy bar plugin that keeps a local, searchable history
of voice transcriptions across speech-to-text tools. The original intent, reflected
in the shared ingestion API and existing documentation, is to intercept the text
produced by any connected voice transcription tool on Omarchy so the user can
find, read, copy, and recover their dictated words later.

Keep the project independent of any particular transcription tool or recognition
engine. VoxType is the first documented integration, not the boundary of the
product. The transcription tool remains responsible for recording audio,
recognizing speech, and delivering text to the destination application. This
plugin captures a copy of the resulting text and provides a shared history.

“Any tool” describes the integration goal, not automatic support for every app.
The current implementation accepts text through a tool's output hook, command
pipeline, or adapter. It does not implement a universal operating-system dictation
listener. Tools that only simulate typing and expose no readable transcript need
a separate integration. Keep this distinction clear in documentation and UI.

## How capture works

The intended flow is:

```text
Speech-to-text tool → output hook / adapter → ingest → local SQLite history
                                               └──→ unchanged text → tool's delivery step
```

The delivery branch applies when the collector runs with `--passthrough`:

```bash
your-transcriber | omarchy-transcripts ingest --source "My dictation tool" --passthrough
```

- `ingest` reads UTF-8 text from standard input. Source labels are freely chosen.
- `--passthrough` echoes the exact original bytes, including whitespace and
  trailing newlines. Handled storage or decoding failures still return the input
  and exit successfully in this mode so collection does not consume a dictation.
- Without passthrough, a failed save returns a nonzero exit status.
- Empty or whitespace-only input is skipped. Repeated dictations remain separate
  entries. Each hook invocation is stored separately, including streaming segments.
- Pause prevents new entries while allowing passthrough to continue.
- Capture records text reaching the hook; it does not confirm successful delivery
  to the destination application.

For VoxType, the README documents an `output.post_process` command. Preserve
existing processors and append collection after them; profiles with their own
hooks need equivalent integration. The installer does not configure speech tools.

## Code map

- `transcripts.py`: Python standard-library CLI, SQLite storage, stdin ingestion,
  search and pagination, copy, manual clipboard capture, pause/resume, Trash and
  restore, JSON export, and panel opening.
- `Transcripts.qml`: Quickshell panel and bar button. Calls the Python helper with
  argument arrays, reads JSON, and refreshes history while the panel is open.
  Provides search, full-text viewing, copy, pause, Trash, and manual clipboard save.
- `manifest.json`: Omarchy bar-widget registration for `local.transcripts`.
- `install.sh`: Validates and copies the plugin, creates the CLI launcher, rescans
  plugins, and enables the bar entry before the audio icon. Refuses to overwrite
  an unrelated launcher.
- `test_transcripts.py`: Tests ingestion, exact passthrough, storage failure,
  pause, Trash/restore/export, concurrent producers, pagination, permissions,
  and literal text handling.
- `README.md`: Installation, tool integration, usage, privacy, and removal guidance.

The runtime targets Omarchy's plugin-capable Quickshell shell, with Python 3.11+
and `wl-clipboard`. It does not target the older Waybar shell. Collection uses
short-lived CLI processes and requires no dedicated background daemon.

## Development principles

- Preserve the shared ingestion interface when adding transcription tools. Prefer
  small tool-specific adapters that feed the existing collector and store.
- Preserve exact passthrough and failure behavior. Saving history must not alter
  dictated text or prevent the connected tool from delivering it on handled errors.
- Keep collection and viewing independent. Disabling the bar plugin does not stop
  collection while a tool's hook remains connected.
- Keep collection local and explicit. The current project records no audio, makes
  no network requests, and performs no keystroke or continuous clipboard monitoring.
  “Save clipboard” is a user-triggered, one-time fallback labeled
  `Clipboard (manual)`; it is not automatic dictation detection.
- Treat transcripts and source labels as data: parameterize SQL, pass subprocess
  arguments as arrays, send copied text over stdin, and render text as plain text.
  Never include transcript contents in error diagnostics.
- Follow existing Omarchy UI components, theme colors, spacing, and keyboard
  navigation. Keep Python dependencies limited to the standard library unless
  a concrete requirement justifies expanding them.
- Update the README when changing integration instructions or user-visible
  behavior. Do not describe planned integrations as already implemented.

## Storage and privacy

The default database is `~/.local/share/omarchy-transcripts/history.sqlite3`.
`XDG_DATA_HOME` changes the data base directory; `OMARCHY_TRANSCRIPTS_DIR` overrides
the transcript directory directly and is the preferred test isolation mechanism.

Each entry stores an ID, UTC timestamp, source, text, and Trash flag. The panel
displays local time. Settings, including the shared pause state, live in the same
database. Preserve user-only directory (`0700`) and database (`0600`) permissions.

Storage is unencrypted. Entries are retained indefinitely, and Trash is recoverable
storage rather than permanent or secure deletion. Export excludes Trash. Preserve
existing history when changing storage or installation behavior.

## Validation and installation

For changes to collector behavior, run the existing isolated test suite:

```bash
python3 -m unittest -v test_transcripts.py
```

For plugin changes, validate against the installed Omarchy tooling when available:

```bash
omarchy plugin validate .
```

Use temporary storage via `OMARCHY_TRANSCRIPTS_DIR` for manual CLI checks. Never
use the user's real transcript database as test data. UI changes also need a
manual panel check; CLI tests do not verify QML behavior.

When installation is part of the requested work, run `bash install.sh`. This
updates the user's live plugin and bar. The installed copy lives at
`${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/local.transcripts/`, with a
launcher at `~/.local/bin/omarchy-transcripts`. Source edits do not update that
copy automatically. Removing collection requires disconnecting the tool's hook;
disabling the panel alone leaves ingestion active and saved history intact.
