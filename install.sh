#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/local.transcripts"
launcher="$HOME/.local/bin/omarchy-transcripts"

omarchy plugin validate "$source_dir"
if [[ -e "$launcher" || -L "$launcher" ]]; then
  if [[ ! -L "$launcher" || "$(readlink -- "$launcher")" != "$plugin_dir/transcripts.py" ]]; then
    echo "Refusing to replace an unrelated launcher: $launcher" >&2
    exit 1
  fi
fi
mkdir -p -- "$plugin_dir" "$HOME/.local/bin"
if [[ "$source_dir" != "$plugin_dir" ]]; then
  install -m 644 "$source_dir/manifest.json" "$source_dir/Transcripts.qml" "$source_dir/README.md" "$source_dir/LICENSE" "$plugin_dir/"
  install -m 755 "$source_dir/transcripts.py" "$plugin_dir/transcripts.py"
else
  chmod +x "$plugin_dir/transcripts.py"
fi
if [[ ! -L "$launcher" ]]; then ln -s -- "$plugin_dir/transcripts.py" "$launcher"; fi
omarchy-shell shell rescanPlugins
omarchy plugin enable local.transcripts --section right --before omarchy.audio
echo "Installed Transcripts. See README.md to connect your dictation tool."
