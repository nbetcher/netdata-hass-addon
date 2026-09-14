#!/bin/sh
trap '' PIPE
# Netdata charts.d module: container_net
# Per-interface rx/tx from container /proc/net/dev
#
# charts.d.plugin sources this file into bash (see plugins.d/charts.d.plugin),
# so bash builtins are used deliberately here: the per-update path must not
# fork. Reading /proc/net/dev with `mapfile` plus `set --` word splitting is
# several times cheaper than spawning awk once per update, which matters on
# the small ARM/Atom boxes Home Assistant usually runs on.

container_net_update_every=5
container_net_priority=60000

CN_NET_DEV="${CN_NET_DEV:-/proc/net/dev}"

# Reconcile disappeared interfaces every N updates (0 disables). Docker veths
# come and go as containers restart; without this their charts would linger
# for the lifetime of the add-on. At update_every=5 this is once a minute.
CN_REAP_EVERY=12

CN_TICKS=0

# iface -> chart id, filled in lazily the first time an interface is seen
declare -A CN_ID=()
# chart id -> iface, keeps ids unique (eth0.100 and eth0-100 both sanitize to
# eth0_100, which would otherwise make two interfaces share one chart)
declare -A CN_OWNER=()
# iface -> 1 for everything seen during a reap pass
declare -A CN_SEEN=()

# Sanitize an interface name into a chart id.
# Returns via CN_S rather than $( ), which would fork a subshell.
cn_sanitize() {
    local s=${1,,}
    s=${s//[^a-z0-9]/_}
    while [[ $s == *__* ]]; do s=${s//__/_}; done
    s=${s#_}
    s=${s%_}
    CN_S=$s
}

# Resolve iface -> unique chart id, returned in CN_S.
cn_id_for() {
    cn_sanitize "$1"
    local base=$CN_S n=1
    while [ -n "${CN_OWNER[$CN_S]}" ] && [ "${CN_OWNER[$CN_S]}" != "$1" ]; do
        CN_S="${base}_${n}"
        n=$((n + 1))
    done
    CN_OWNER[$CN_S]=$1
}

# Append a chart definition to CN_OUT (dynamic scope: CN_OUT is the caller's local).
cn_chart_def() {
    CN_OUT="${CN_OUT}CHART container_net_${1} container_net_${1} 'Container Net ${2}' kilobits/s network container.net area
DIMENSION received 'rx' incremental 8 1024
DIMENSION sent 'tx' incremental -8 1024
"
}

# Append an obsoletion marker so netdata can retire a vanished interface.
# Needs priority and update_every to reach the options field.
cn_chart_obsolete() {
    CN_OUT="${CN_OUT}CHART container_net_${1} container_net_${1} 'Container Net ${2}' kilobits/s network container.net area ${container_net_priority} ${container_net_update_every} obsolete
"
}

container_net_check() {
    [ -e "$CN_NET_DEV" ] || return 1
    return 0
}

container_net_create() {
    local CN_OUT='' iface id
    local -a CN_LINES=()
    local line noglob=0

    case $- in *f*) noglob=1 ;; esac
    set -f
    mapfile -t CN_LINES < "$CN_NET_DEV"
    for line in "${CN_LINES[@]}"; do
        set -- $line
        [ $# -ge 10 ] || continue
        [[ $1 == *: ]] || continue          # skips the two header rows
        iface=${1%:}
        [ "$iface" = "lo" ] && continue
        cn_id_for "$iface"
        id=$CN_S
        CN_ID[$iface]=$id
        cn_chart_def "$id" "$iface"
    done
    [ $noglob -eq 1 ] || set +f

    if [ -z "$CN_OUT" ]; then
        printf '%s\n%s\n' \
            "CHART container_net.none container_net.none 'No interfaces found' status network container.net area" \
            "DIMENSION none none absolute 1 1"
        return 0
    fi

    printf '%s' "$CN_OUT"
    return 0
}

container_net_update() {
    local us="$1"
    local CN_OUT='' iface rx tx id
    local -a CN_LINES=()
    local line noglob=0 reap=0

    if [ ! -r "$CN_NET_DEV" ]; then
        printf '%s\n%s\n%s\n%s\n%s\n' \
            "CHART container_net.disabled container_net.disabled 'container_net disabled' status network container.net area" \
            "DIMENSION disabled disabled absolute 1 1" \
            "BEGIN container_net.disabled $us" \
            "SET disabled = 1" \
            "END"
        return 0
    fi

    CN_TICKS=$((CN_TICKS + 1))
    if [ "$CN_REAP_EVERY" -gt 0 ] && [ $((CN_TICKS % CN_REAP_EVERY)) -eq 0 ]; then
        reap=1
        CN_SEEN=()
    fi

    case $- in *f*) noglob=1 ;; esac
    set -f
    mapfile -t CN_LINES < "$CN_NET_DEV"
    for line in "${CN_LINES[@]}"; do
        set -- $line
        [ $# -ge 10 ] || continue
        [[ $1 == *: ]] || continue
        iface=${1%:}
        [ "$iface" = "lo" ] && continue
        rx=$2
        tx=${10}

        id=${CN_ID[$iface]}
        if [ -z "$id" ]; then
            # new interface since the last pass: define it inline, no rescan needed
            cn_id_for "$iface"
            id=$CN_S
            CN_ID[$iface]=$id
            cn_chart_def "$id" "$iface"
        fi
        [ $reap -eq 1 ] && CN_SEEN[$iface]=1

        CN_OUT="${CN_OUT}BEGIN container_net_${id} ${us}
SET received = ${rx}
SET sent = ${tx}
END
"
    done
    [ $noglob -eq 1 ] || set +f

    if [ $reap -eq 1 ]; then
        for iface in "${!CN_ID[@]}"; do
            if [ -z "${CN_SEEN[$iface]}" ]; then
                id=${CN_ID[$iface]}
                cn_chart_obsolete "$id" "$iface"
                unset "CN_ID[$iface]"
                unset "CN_OWNER[$id]"
            fi
        done
        CN_SEEN=()
    fi

    printf '%s' "$CN_OUT"
    return 0
}
