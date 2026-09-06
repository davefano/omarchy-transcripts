#!/usr/bin/env bash
# Run the real panel in a separate Quickshell process with disposable data.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_dir=$(mktemp -d)
pointer_position=$(hyprctl cursorpos -j | python3 -c 'import json,sys; p=json.load(sys.stdin); print("{x=%d,y=%d}" % (p["x"], p["y"]))')
cleanup() {
    hyprctl eval "hl.dispatch(hl.dsp.cursor.move($pointer_position))" >/dev/null || :
    rm -rf -- "$test_dir"
}
trap cleanup EXIT
export OMARCHY_TRANSCRIPTS_DIR="$test_dir/store"
export TRANSCRIPTS_TEST_COPY="$test_dir/copied.txt"
cp -- "$source_dir/Transcripts.qml" "$source_dir/transcripts.py" "$test_dir/"
cp -- "$source_dir/test_panel.qml" "$test_dir/shell.qml"
ln -s /usr/share/omarchy/shell/Commons "$test_dir/Commons"
ln -s /usr/share/omarchy/shell/Ui "$test_dir/Ui"
mkdir "$test_dir/bin"
cat > "$test_dir/bin/wl-copy" <<'COPY'
#!/usr/bin/env bash
cat > "$TRANSCRIPTS_TEST_COPY"
COPY
chmod +x "$test_dir/bin/wl-copy"
export PATH="$test_dir/bin:$PATH"
python3 - "$test_dir" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import transcripts
with transcripts.connect() as db:
    db.executemany("INSERT INTO transcripts(created_at,source,text) VALUES (?,?,?)",
                   [("2026-09-06T12:00:00+00:00", "Test tool", "--help sample " + str(i))
                    for i in range(51)])
PY
test_status=0
timeout --kill-after=2s 45s qs -p "$test_dir" --no-color > "$test_dir/output" 2>&1 || test_status=$?
cat "$test_dir/output"
test "$test_status" -eq 0
rg -q 'PANEL_TESTS_PASSED' "$test_dir/output"
test "$(cat "$TRANSCRIPTS_TEST_COPY")" = '--help sample 50'
