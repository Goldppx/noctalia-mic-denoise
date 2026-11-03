#!/usr/bin/env sh
# Mic Denoise - installer.
#
# Registers this checkout as a Noctalia plugin source and enables the plugin.
# Nothing is written outside the user's own state/config directories, and no
# root privileges are needed.
#
#   ./install.sh             # register + enable, then print next steps
#   ./install.sh --restart   # also restart PipeWire if the virtual source is not loaded yet
#   SOURCE_NAME=my-plugins ./install.sh
set -eu

PLUGIN_ID="goldesquemoon/mic-denoise"
SOURCE_NAME="${SOURCE_NAME:-mic-denoise}"
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONF="$HOME/.config/pipewire/pipewire.conf.d/50-mic-denoise.conf"
RESTART=0

for arg in "$@"; do
    case "$arg" in
    --restart) RESTART=1 ;;
    -h | --help)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        printf 'install: unknown option %s\n' "$arg" >&2
        exit 2
        ;;
    esac
done

die() {
    printf 'install: %s\n' "$*" >&2
    exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

have noctalia || die "noctalia CLI not found in PATH"
have pactl || die "pactl not found - install libpulse"
have pw-cli || die "pw-cli not found - install pipewire"

[ -x "$REPO_DIR/mic-denoise/assets/mic-denoise.sh" ] ||
    chmod +x "$REPO_DIR/mic-denoise/assets/mic-denoise.sh" 2>/dev/null ||
    true

if [ ! -f /usr/lib/ladspa/librnnoise_ladspa.so ]; then
    printf 'install: warning: /usr/lib/ladspa/librnnoise_ladspa.so missing.\n' >&2
    printf 'install:          install noise-suppression-for-voice, otherwise the chain will not load.\n' >&2
fi

# 1. plugin source (idempotent)
if noctalia msg plugins source list 2>/dev/null | awk '{print $1}' | grep -qx "$SOURCE_NAME"; then
    printf 'source "%s" already registered\n' "$SOURCE_NAME"
else
    noctalia msg plugins source add "$SOURCE_NAME" path "$REPO_DIR" >/dev/null
    printf 'registered source "%s" -> %s\n' "$SOURCE_NAME" "$REPO_DIR"
fi

# 2. enable (idempotent)
noctalia msg plugins enable "$PLUGIN_ID" >/dev/null
printf 'enabled %s\n' "$PLUGIN_ID"

# 3. wait for the service to bootstrap the PipeWire snippet
i=0
while [ "$i" -lt 15 ] && [ ! -f "$CONF" ]; do
    i=$((i + 1))
    sleep 0.2
done
if [ -f "$CONF" ]; then
    printf 'PipeWire snippet: %s\n' "$CONF"
else
    printf 'PipeWire snippet: not created yet (the service writes it on first status poll)\n'
fi

# 4. is the virtual source live?
if pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx rnnoise_source; then
    printf 'virtual source rnnoise_source: loaded\n'
else
    printf 'virtual source rnnoise_source: not loaded yet\n'
    if [ "$RESTART" -eq 1 ]; then
        printf 'restarting PipeWire...\n'
        systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
        sleep 3
        if pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx rnnoise_source; then
            printf 'virtual source rnnoise_source: loaded\n'
        else
            printf 'install: still missing - check "journalctl --user -u pipewire -b"\n' >&2
        fi
    else
        printf 'run this once to load it:  systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service\n'
    fi
fi

cat <<EOF

Next steps
  1. Control-center tile: Settings -> Control Center -> Shortcuts -> add "Mic Denoise"
     (config.toml equivalent:)

     [[control_center.shortcuts]]
     type = "${PLUGIN_ID}:denoise"

  2. Optional bar widget: Settings -> Bar -> add widget "Mic Denoise"

  3. Keybind example:

     binds {
         Mod+Shift+M { spawn "noctalia" "msg" "plugin" "${PLUGIN_ID}:state" "all" "toggle"; }
     }

Verify
  noctalia msg plugins list | grep mic-denoise
  pactl get-default-source
  sh ${REPO_DIR}/tests/smoke.sh
EOF
