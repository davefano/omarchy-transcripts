# Transcripts for Omarchy

A native Omarchy bar plugin for local speech-to-text history. Search across tools,
open the full text, copy it, pause collection, and move entries to recoverable Trash.
Supports the Quickshell-based Omarchy shell (not older Waybar-based versions).

## Install

Requires Omarchy's plugin-capable shell, Python 3.11+, and `wl-clipboard`.
From this directory, run `bash install.sh`. The plugin appears before the audio
icon in the right side of the bar. No root access or background daemon is needed.

Installed plugin: `~/.config/omarchy/plugins/local.transcripts/`.
Command: `~/.local/bin/omarchy-transcripts`.
Open from a terminal with `omarchy-transcripts open`.
The installer does not change your speech tool's configuration.

## Connect VoxType

VoxType's documented post-processing hook runs after recognition and before output:
https://voxtype.io/docs/CONFIGURATION#outputpost_process

Add this table to `~/.config/voxtype/config.toml`, replacing the path with your own
home directory's absolute path:

```toml
[output.post_process]
command = "/home/YOUR_USER/.local/bin/omarchy-transcripts ingest --source VoxType --passthrough"
timeout_ms = 2000
```

Restart VoxType when it is idle: `systemctl --user restart voxtype`.
The hook returns its input unchanged. A storage error still returns the original
text so dictation can continue. Copy/paste, typing mode, and engine selection stay
with VoxType. The history contains recognized text even if delivery to an app fails.

If a post-processing hook already exists, append this collector **after** the
existing processor rather than replacing it. Profiles with their own post-process
commands also need the collector appended. Streaming tools may invoke their hook
per segment; this first version saves each invocation as a separate entry.

## Connect other tools

The store is independent of the recognition tool. Send each completed transcript
as UTF-8 on standard input:

```bash
your-transcriber | omarchy-transcripts ingest --source "My dictation tool" --passthrough
```

Use `--passthrough` when another step needs to receive the same text. Omit it when
the producer only needs to log text. Source labels are freely chosen. Repeated
dictations are preserved as separate entries.

There is no universal OS event identifying "this text was dictated." Automatic
collection requires a tool's output hook, command output, or an adapter. Apps with
only simulated typing and no readable output need a separate integration. This
plugin does not record keystrokes or monitor every clipboard change. The panel's
**Save clipboard** action explicitly saves the current text once, labelled
"Clipboard (manual)". It is a fallback, not automatic tool detection.

## Data and privacy

Text, source, and UTC timestamp are stored in
`~/.local/share/omarchy-transcripts/history.sqlite3`. The panel displays local time.
`XDG_DATA_HOME` is supported. The directory is user-only (0700), and the database
is user-only (0600). This is ordinary unencrypted local storage, not a vault.
No audio, application contents, passwords from unrelated clipboard activity, or
network requests are collected. Connected tools can still dictate sensitive text;
use Pause when you do not want it retained.

Entries are retained indefinitely. Trash is recoverable and still occupies the
database; it is not secure deletion. Export excludes Trash:

```bash
omarchy-transcripts export > transcripts.json
omarchy-transcripts list --query "meeting"
omarchy-transcripts get 42
omarchy-transcripts pause
omarchy-transcripts resume
```

List returns JSON with pagination (`--limit 50 --offset 50`). Search is literal,
with ASCII case-insensitive matching; non-ASCII text matches exactly. SQL syntax
and shell metacharacters in transcripts are treated as ordinary data.

## Disable / undo

First remove the collector from your dictation tool's hook, then restart that tool.
Run `omarchy plugin disable local.transcripts` to remove the bar entry. Saved data
is preserved. If you keep the hook connected, collection continues even with the
panel disabled: the collector and viewer are independent.

## Development

```bash
python3 -m unittest -v test_transcripts.py
omarchy plugin validate .
bash install.sh
```

Tests use temporary storage and never read or alter your real history. To manually
test with an isolated store, set `OMARCHY_TRANSCRIPTS_DIR` for the CLI process.
The installed plugin and this source directory are separate; rerun the installer
after editing the source.
