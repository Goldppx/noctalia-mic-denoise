#!/bin/sh
# Mic Denoise - backend used by the Noctalia plugin entries.
#
#   mic-denoise.sh status  <denoised> <mic> <data-dir>
#   mic-denoise.sh on|off|toggle <denoised> <mic> <data-dir>
#   mic-denoise.sh devices <denoised> <mic> <data-dir>
#   mic-denoise.sh set-mic <denoised> <mic|""> <data-dir> <conf-path> <want-on:0|1>
#
# Switching is done through the default source: with denoising off the PipeWire
# filter-chain keeps no consumer, so PipeWire suspends the whole graph and no DSP
# work happens at all. Capture streams are moved along so nothing keeps the graph
# alive by accident.
#
# <mic> is the explicitly chosen microphone ("" = follow the last used one, or
# the first available input). The choice is persisted in <data-dir>.
set -eu

action=${1:-status}
denoised=${2:-rnnoise_source}
mic_pref=${3:-}
data_dir=${4:-}
conf=${5:-}
want=${6:-0}

state_file=""
[ -n "$data_dir" ] && state_file="$data_dir/raw_source"
choice_file=""
[ -n "$data_dir" ] && choice_file="$data_dir/hardware_source"

sources() { pactl list short sources 2>/dev/null || true; }

idx_of() { sources | awk -v n="$1" '$2 == n { print $1; exit }'; }

default_source() { pactl get-default-source 2>/dev/null || true; }

has_source() { sources | awk -v n="$1" '$2 == n { found = 1 } END { exit !found }'; }

# First input source that is not the denoised one and not a monitor.
auto_raw() { sources | awk -v dn="$denoised" '$2 != dn && $2 !~ /[.]monitor$/ { print $2; exit }'; }

raw_source() {
    if [ -n "$mic_pref" ] && has_source "$mic_pref"; then
        printf '%s' "$mic_pref"
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
    printf '%s' "$1" >"$state_file" 2>/dev/null || true
}

save_choice() {
    [ -n "$choice_file" ] || return 0
    mkdir -p "$data_dir" 2>/dev/null || true
    if [ -n "$1" ]; then
        printf '%s' "$1" >"$choice_file" 2>/dev/null || true
    else
        rm -f "$choice_file" 2>/dev/null || true
    fi
}

# Wait for the PulseAudio/PipeWire socket to come back after a restart.
wait_audio() {
    i=0
    while [ "$i" -lt 60 ]; do
        pactl info >/dev/null 2>&1 && return 0
        i=$((i + 1))
        sleep 0.25
    done
    return 1
}

rewrite_target() { # mic
    [ -n "$conf" ] && [ -f "$conf" ] || return 0
    tmp="$conf.micdenoise.tmp"
    awk -v mic="$1" '
        /^[[:space:]]*node[.]target[[:space:]]*=/ {
            printf "            node.target  = \"%s\"\n", mic
            next
        }
        { print }
    ' "$conf" >"$tmp" && mv "$tmp" "$conf"
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
list)
    # human readable listing for the terminal button
    current=$(default_source)
    echo "Available inputs (put one of these names into the plugin setting \"Microphone\"):"
    echo
    pactl list sources 2>/dev/null | awk -v cur="$current" -v dn="$denoised" '
        function flush() {
            if (name != "" && name != dn && (mon == "" || mon == "n/a")) {
                tag = (name == cur) ? "   [current default]" : ""
                printf "  %s%s\n      %s\n\n", name, tag, desc
            }
            name = ""; desc = ""; mon = ""
        }
        /^Source #/ { flush(); next }
        /^[[:space:]]*Name: /            { name = $2 }
        /^[[:space:]]*Description: /     { sub(/^[[:space:]]*Description: /, ""); desc = $0 }
        /^[[:space:]]*Monitor of Sink: / { mon = $4 }
        END { flush() }
    '
    echo "The denoised source \"$denoised\" is not listed: it is the output, not a microphone."
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
        exec sh "$0" off "$denoised" "$mic_pref" "$data_dir"
    else
        exec sh "$0" on "$denoised" "$mic_pref" "$data_dir"
    fi
    ;;
set-mic)
    # resolve "auto" to a concrete microphone: the filter-chain needs a target
    requested=$mic_pref
    mic=$mic_pref
    if [ -z "$mic" ] || ! has_source "$mic"; then
        mic=$(auto_raw)
    fi
    if [ -z "$mic" ]; then
        echo "error=no microphone found" >&2
        exit 1
    fi
    [ "$mic" = "$denoised" ] && { echo "error='$mic' is the denoised source, not a microphone" >&2; exit 1; }

    # an explicit pick is persisted; "auto" clears it so the next poll re-detects
    if [ -n "$requested" ]; then save_choice "$requested"; else save_choice ""; fi
    remember_raw "$mic"

    # Already pinned to this microphone? Re-rendering the same config would cost a
    # needless PipeWire restart (and a second of silence), so only restore state.
    current_target=""
    if [ -n "$conf" ] && [ -f "$conf" ]; then
        current_target=$(sed -n 's/^[[:space:]]*node[.]target[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$conf" | head -1)
    fi
    if [ -n "$current_target" ] && [ "$current_target" = "$mic" ]; then
        if [ "$want" = "1" ]; then
            sh "$0" on "$denoised" "$mic" "$data_dir" >/dev/null || true
        else
            sh "$0" off "$denoised" "$mic" "$data_dir" >/dev/null || true
        fi
        echo "mic=$mic"
        echo "reloaded=0"
        exit 0
    fi

    rewrite_target "$mic"

    systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service >/dev/null 2>&1 || true
    wait_audio || { echo "error=PipeWire did not come back after restart" >&2; exit 1; }

    if [ "$want" = "1" ]; then
        sh "$0" on "$denoised" "$mic" "$data_dir" >/dev/null || true
    else
        sh "$0" off "$denoised" "$mic" "$data_dir" >/dev/null || true
    fi
    echo "mic=$mic"
    echo "reloaded=1"
    ;;
*)
    echo "usage: $0 [status|devices|on|off|toggle|set-mic] <denoised> <mic> <data-dir> [conf] [want]" >&2
    exit 2
    ;;
esac
