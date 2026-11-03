#!/usr/bin/env sh
# Mic Denoise - smoke test (no root, read-only).
#
#   sh tests/smoke.sh
#
# Checks the manifest, the entry wiring, the translations and the backend script.
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLUGIN_DIR="$REPO_DIR/mic-denoise"
MANIFEST="$PLUGIN_DIR/plugin.toml"
fail=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
    printf '  FAIL  %s\n' "$1" >&2
    fail=$((fail + 1))
}
check() { # description, condition exit code
    if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

printf 'manifest\n'
for key in id name version plugin_api author license; do
    grep -qE "^$key[[:space:]]*=" "$MANIFEST"
    check "has $key" $?
done
grep -q '^id[[:space:]]*=[[:space:]]*"goldesquemoon/mic-denoise"' "$MANIFEST"
check 'id is goldesquemoon/mic-denoise' $?
grep -qE '^plugin_api[[:space:]]*=[[:space:]]*[0-9]+' "$MANIFEST"
check 'plugin_api is an integer' $?

printf 'entries\n'
# every declared entry file must exist, and every entry id must be unique
entries=$(mktemp)
ids=$(mktemp)
awk -F'"' '/^entry[[:space:]]*=/ { print id, $2 } /^id[[:space:]]*=/ { id = $2 }' "$MANIFEST" >"$entries"
while read -r id entry; do
    [ -n "${entry:-}" ] || continue
    if [ -f "$PLUGIN_DIR/$entry" ]; then
        ok "$id -> $entry"
    else
        bad "$id -> $entry missing"
    fi
    printf '%s\n' "$id" >>"$ids"
done <"$entries"
if [ -s "$ids" ] && [ "$(sort "$ids" | uniq -d | wc -l)" -eq 0 ]; then
    ok 'entry ids are unique'
else
    bad 'entry ids are unique'
fi
rm -f "$entries" "$ids"

printf 'assets\n'
[ -f "$PLUGIN_DIR/assets/mic-denoise.sh" ]
check 'backend script present' $?
[ -x "$PLUGIN_DIR/assets/mic-denoise.sh" ]
check 'backend script is executable' $?
sh -n "$PLUGIN_DIR/assets/mic-denoise.sh"
check 'backend script parses (sh -n)' $?
grep -q '@SOURCE@' "$PLUGIN_DIR/assets/50-mic-denoise.conf.in"
check 'config template has @SOURCE@ placeholder' $?
grep -q '@TARGET@' "$PLUGIN_DIR/assets/50-mic-denoise.conf.in"
check 'config template has @TARGET@ placeholder' $?

printf 'translations\n'
for file in en zh-Hans; do
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$PLUGIN_DIR/translations/$file.json" 2>/dev/null
        check "$file.json is valid JSON" $?
    else
        ok "$file.json skipped (no python3)"
    fi
done
# every noctalia.tr key used in the scripts must exist in en.json
if command -v python3 >/dev/null 2>&1; then
    python3 - "$PLUGIN_DIR" <<'EOF'
import json, pathlib, re, sys
plugin = pathlib.Path(sys.argv[1])
en = json.load(open(plugin / "translations" / "en.json"))
flat = set()
def walk(node, prefix=""):
    for key, value in node.items():
        path = f"{prefix}{key}"
        if isinstance(value, dict):
            walk(value, path + ".")
        else:
            flat.add(path)
walk(en)
used = set()
for script in plugin.glob("*.luau"):
    used |= set(re.findall(r'noctalia\.tr(?:p)?\(\s*"([^"]+)"', script.read_text()))
missing = sorted(used - flat)
if missing:
    print("  FAIL  missing translation keys: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print(f"  ok    all {len(used)} tr keys resolve")
EOF
    fail=$((fail + $?))
fi

printf 'labels\n'
for key in $(grep -oE '(label|description)_key[[:space:]]*=[[:space:]]*"[^"]+"' "$MANIFEST" | sed 's/.*"\(.*\)"/\1/'); do
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json,sys
d=json.load(open('$PLUGIN_DIR/translations/en.json'))
node=d
for part in sys.argv[1].split('.'):
    node=node[part]
" "$key" 2>/dev/null
        check "en.json has $key" $?
    fi
done

printf 'backend\n'
if command -v pactl >/dev/null 2>&1; then
    out=$(sh "$PLUGIN_DIR/assets/mic-denoise.sh" status rnnoise_source "" "")
    printf '%s\n' "$out" | grep -q '^enabled=[01]$'
    check 'status reports enabled' $?
    printf '%s\n' "$out" | grep -q '^default='
    check 'status reports the default source' $?
    printf '%s\n' "$out" | grep -q '^raw='
    check 'status reports the raw microphone' $?
else
    ok 'backend skipped (pactl missing)'
fi

if [ "$fail" -eq 0 ]; then
    printf '\nall checks passed\n'
else
    printf '\n%d check(s) failed\n' "$fail" >&2
    exit 1
fi
