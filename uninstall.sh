#!/usr/bin/env sh
# Mic Denoise - uninstaller.
#
#   ./uninstall.sh            # disable the plugin and hand the mic back
#   ./uninstall.sh --purge    # also remove the generated PipeWire snippet
set -eu

PLUGIN_ID="goldesquemoon/mic-denoise"
SOURCE_NAME="${SOURCE_NAME:-mic-denoise}"
REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONF="$HOME/.config/pipewire/pipewire.conf.d/50-mic-denoise.conf"
DENOISED=rnnoise_source
PURGE=0

for arg in "$@"; do
    case "$arg" in
    --purge) PURGE=1 ;;
    -h | --help)
        sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        printf 'uninstall: unknown option %s\n' "$arg" >&2
        exit 2
        ;;
    esac
done

# 1. hand the microphone back before the plugin stops managing it
if command -v pactl >/dev/null 2>&1; then
    current=$(pactl get-default-source 2>/dev/null || true)
    if [ "$current" = "$DENOISED" ]; then
        raw=$(pactl list short sources 2>/dev/null |
            awk -v dn="$DENOISED" '$2 != dn && $2 !~ /[.]monitor$/ { print $2; exit }')
        if [ -n "${raw:-}" ]; then
            pactl set-default-source "$raw"
            printf 'default source restored: %s\n' "$raw"
        fi
    fi
fi

# 2. disable the plugin
if command -v noctalia >/dev/null 2>&1; then
    noctalia msg plugins disable "$PLUGIN_ID" >/dev/null 2>&1 || true
    printf 'disabled %s\n' "$PLUGIN_ID"
    if [ -n "${SOURCE_NAME:-}" ]; then
        noctalia msg plugins source remove "$SOURCE_NAME" >/dev/null 2>&1 && \
            printf 'removed source "%s"\n' "$SOURCE_NAME" || true
    fi
fi

# 3. optional: drop the generated snippet
if [ "$PURGE" -eq 1 ]; then
    rm -f "$CONF" && printf 'removed %s\n' "$CONF"
    printf 'restart PipeWire to drop the filter-chain:\n'
    printf '  systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service\n'
else
    printf 'PipeWire snippet kept at %s (use --purge to remove it)\n' "$CONF"
fi
