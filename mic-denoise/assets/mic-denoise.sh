#!/bin/sh
# Mic Denoise - backend used by the Noctalia plugin entries.
#
#   mic-denoise.sh status <denoised> <raw-pref> <data-dir>
#   mic-denoise.sh on|off|toggle <denoised> <raw-pref> <data-dir>
#
# Switching is done through the default source: when denoising is off the
# PipeWire filter-chain has no consumer left, so PipeWire suspends the whole
# graph and no DSP work happens at all. Existing capture streams are moved along
# so nothing keeps the graph alive by accident.
set -eu

action=${1:-status}
denoised=${2:-rnnoise_source}
raw_pref=${3:-}
data_dir=${4:-}

state_file=""
[ -n "$data_dir" ] && state_file="$data_dir/raw_source"

sources() { pactl list short sources 2>/dev/null || true; }

idx_of() { sources | awk -v n="$1" '$2 == n { print $1; exit }'; }

default_source() { pactl get-default-source 2>/dev/null || true; }

# First input source that is not the denoised one and not a monitor.
auto_raw() { sources | awk -v dn="$denoised" '$2 != dn && $2 !~ /[.]monitor$/ { print $2; exit }'; }

has_source() { sources | awk -v n="$1" '$2 == n { found = 1 } END { exit !found }'; }

raw_source() {
    if [ -n "$raw_pref" ]; then
        printf '%s' "$raw_pref"
        return
    fi
    if [ -n "$state_file" ] && [ -s "$state_file" ]; then
        saved=$(cat "$state_file")
        if [ -n "$saved" ] && has_source "$saved"; then
            printf '%s' "$saved"
            return
        fi
    fi
    auto_raw
}

# move every capture stream that reads from source $1 onto source $2
move_streams() {
    from=$(idx_of "$1")
    to=$(idx_of "$2")
    [ -n "$from" ] && [ -n "$to" ] || return 0
    [ "$from" = "$to" ] && return 0
    for so in $(pactl list short source-outputs 2>/dev/null | awk -v f="$from" '$2 == f { print $1 }'); do
        pactl move-source-output "$so" "$to" >/dev/null 2>&1 || true
    done
}

remember_raw() {
    [ -n "$state_file" ] && [ -n "$1" ] || return 0
    mkdir -p "$data_dir" 2>/dev/null || true
    printf '%s' "$1" > "$state_file" 2>/dev/null || true
}

case "$action" in
status)
    current=$(default_source)
    if [ "$current" = "$denoised" ]; then echo "enabled=1"; else echo "enabled=0"; fi
    echo "default=$current"
    if has_source "$denoised"; then echo "available=1"; else echo "available=0"; fi
    echo "denoised=$denoised"
    echo "raw=$(raw_source)"
    ;;
on)
    if ! has_source "$denoised"; then
        echo "error=denoised source '$denoised' not found" >&2
        exit 1
    fi
    raw=$(raw_source)
    remember_raw "$raw"
    pactl set-default-source "$denoised"
    [ -n "$raw" ] && move_streams "$raw" "$denoised" || true
    echo "enabled=1"
    ;;
off)
    raw=$(raw_source)
    if [ -z "$raw" ]; then
        echo "error=no raw microphone found" >&2
        exit 1
    fi
    pactl set-default-source "$raw"
    move_streams "$denoised" "$raw" || true
    echo "enabled=0"
    ;;
toggle)
    if [ "$(default_source)" = "$denoised" ]; then
        exec sh "$0" off "$denoised" "$raw_pref" "$data_dir"
    else
        exec sh "$0" on "$denoised" "$raw_pref" "$data_dir"
    fi
    ;;
*)
    echo "usage: $0 [status|on|off|toggle] <denoised-source> <raw-pref> <data-dir>" >&2
    exit 2
    ;;
esac
