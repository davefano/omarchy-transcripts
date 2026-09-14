#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_id="io.github.davefano.transcripts"
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$plugin_id"
legacy_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/local.transcripts"
launcher="$HOME/.local/bin/omarchy-transcripts"
cli_only=false
migrate=false
for arg in "$@"; do
  case "$arg" in
    --cli-only) cli_only=true ;;
    --migrate) migrate=true ;;
    *) echo "Usage: bash install.sh [--cli-only] [--migrate]" >&2; exit 1 ;;
  esac
done

if [[ "$cli_only" == true && "$source_dir" != "$plugin_dir" ]]; then
  echo "Run --cli-only from the installed plugin directory: $plugin_dir/install.sh" >&2
  exit 1
fi
if [[ "$source_dir" != "$plugin_dir" && ( -e "$plugin_dir/.git" || -L "$plugin_dir" ) ]]; then
  echo "Refusing to overwrite a Git-managed or linked plugin. Update that checkout instead." >&2
  exit 1
fi
if [[ "$migrate" == false && -e "$legacy_dir/manifest.json" ]]; then
  echo "Legacy installation found. Use --migrate to switch its launcher and disable its bar entry." >&2
  exit 1
fi

omarchy plugin validate "$source_dir"
if [[ -e "$launcher" || -L "$launcher" ]]; then
  if [[ ! -L "$launcher" ]]; then
    echo "Refusing to replace an unrelated launcher: $launcher" >&2
    exit 1
  fi
  target=$(readlink -- "$launcher")
  if [[ "$target" == "$legacy_dir/transcripts.py" && "$migrate" == false ]]; then
    echo "Legacy launcher found. Use --migrate to switch it to the new collector." >&2
    exit 1
  fi
  if [[ "$target" != "$plugin_dir/transcripts.py" && ! ( "$migrate" == true && "$target" == "$legacy_dir/transcripts.py" ) ]]; then
    echo "Refusing to replace an unrelated launcher: $launcher" >&2
    exit 1
  fi
fi
mkdir -p -- "$plugin_dir" "$HOME/.local/bin"
if [[ "$source_dir" != "$plugin_dir" ]]; then
  install -m 644 "$source_dir/manifest.json" "$source_dir/Transcripts.qml" "$source_dir/README.md" "$source_dir/LICENSE" "$source_dir/install.sh" "$plugin_dir/"
  install -m 755 "$source_dir/transcripts.py" "$plugin_dir/transcripts.py"
else
  chmod +x "$plugin_dir/transcripts.py"
fi
# Replace a recognized launcher atomically, so an active hook never sees a gap.
link_dir=$(mktemp -d "$HOME/.local/bin/.transcripts-setup.XXXXXX")
trap 'rmdir -- "$link_dir"' EXIT
ln -s -- "$plugin_dir/transcripts.py" "$link_dir/omarchy-transcripts"
mv -Tf -- "$link_dir/omarchy-transcripts" "$launcher"
if [[ "$cli_only" == false ]]; then
  omarchy-shell shell rescanPlugins
  omarchy plugin enable "$plugin_id" --section right --before omarchy.audio
fi
if [[ "$migrate" == true && -e "$legacy_dir/manifest.json" ]]; then
  omarchy plugin disable local.transcripts
  echo "Legacy plugin disabled; its files and your saved history are preserved."
fi
echo "Transcripts command ready. See README.md to connect your dictation tool."
