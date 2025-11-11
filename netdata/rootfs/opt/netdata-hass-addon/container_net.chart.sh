#!/bin/sh
# Netdata charts.d module: container_net
# Per-interface rx/tx from container /proc/net/dev

container_net_update_every=1
container_net_priority=60000

CN_NET_DEV="/proc/net/dev"
# rescan every N updates to catch new veths; 0 to disable
CN_RESCAN_EVERY=15

CN_KNOWN_IDS=""
CN_TICKS=0

# define chart for iface
cn_define_chart() {
    id="$1"
    iface="$2"
    echo "CHART container_net_${id} '' 'Container Net ${iface}' 'kilobits/s' 'network' 'container.net' stacked"
    echo "DIMENSION received 'rx' incremental 8 1024"
    echo "DIMENSION sent 'tx' incremental -8 1024"
}

# helper: check if id is already known
cn_has_id() {
    needle="$1"
    for w in $CN_KNOWN_IDS; do
        [ "$w" = "$needle" ] && return 0
    done
    return 1
}

container_net_check() {
    [ -e "$CN_NET_DEV" ] || return 1
    return 0
}

container_net_create() {
    # discover interfaces and emit charts
    DATA="$(awk '
        function sanitize(s,   out,c,head,tail) {
            out=""
            for (i=1;i<=length(s);i++) {
                c=substr(s,i,1)
                if (c>="A" && c<="Z") c=tolower(c)
                out=out c
            }
            s=out
            gsub(/[^a-z0-9]/, "_", s)
            gsub(/_+/, "_", s)
            sub(/^_/, "", s)
            sub(/_$/, "", s)
            if (length(s) <= 20) return s
            head=substr(s,1,8)
            tail=substr(s,length(s)-11,12)
            return head tail
        }
        NR>2 {
            iface=$1; gsub(/:/,"",iface)
            if (iface=="lo") next
            id=sanitize(iface)
            printf("CHART %s %s '\''Container Net %s'\'' '\''kilobits/s'\'' '\''network'\'' '\''container.net'\'' stacked\n",
                   "container_net_" id, "''", iface)
            print "DIMENSION received '\''rx'\'' incremental 8 1024"
            print "DIMENSION sent '\''tx'\'' incremental -8 1024"
            printf("#ID %s\n", id)
        }
    ' "$CN_NET_DEV" 2>/dev/null)"

    if [ -z "$DATA" ]; then
        echo "CHART container_net.none '' 'No interfaces found' 'status' 'network' 'container.net' area"
        echo "DIMENSION none none absolute 1 1"
        CN_KNOWN_IDS=""
        return 0
    fi

    while IFS= read -r line; do
        case "$line" in
            \#ID\ *) CN_KNOWN_IDS="$CN_KNOWN_IDS ${line#\#ID }" ;;
            *)       echo "$line" ;;
        esac
    done <<EOF
$DATA
EOF

    # trim
    CN_KNOWN_IDS=$(echo "$CN_KNOWN_IDS" | sed 's/^ *//')
    return 0
}

container_net_update() {
    us="$1"
    CN_TICKS=$((CN_TICKS + 1))

    if [ ! -r "$CN_NET_DEV" ]; then
        echo "CHART container_net.disabled '' 'container_net disabled' 'status' 'network' 'container.net' area"
        echo "DIMENSION disabled disabled absolute 1 1"
        echo "BEGIN container_net.disabled $us"
        echo "SET disabled = 1"
        echo "END"
        return 0
    fi

    # main fast path: single awk
    awk -v TS="$us" '
        function sanitize(s,   out,c,head,tail) {
            out=""
            for (i=1;i<=length(s);i++) {
                c=substr(s,i,1)
                if (c>="A" && c<="Z") c=tolower(c)
                out=out c
            }
            s=out
            gsub(/[^a-z0-9]/, "_", s)
            gsub(/_+/, "_", s)
            sub(/^_/, "", s)
            sub(/_$/, "", s)
            if (length(s) <= 20) return s
            head=substr(s,1,8)
            tail=substr(s,length(s)-11,12)
            return head tail
        }
        NR>2 {
            iface=$1; gsub(/:/,"",iface)
            if (iface=="lo") next
            id=sanitize(iface)
            rx=$2; tx=$10
            if (rx !~ /^[0-9]+$/) rx=0
            if (tx !~ /^[0-9]+$/) tx=0
            printf("BEGIN container_net_%s %s\n", id, TS)
            printf("SET received = %s\n", rx)
            printf("SET sent = %s\n", tx)
            printf("END\n")
        }
    ' "$CN_NET_DEV"

    # optional dynamic discovery
    if [ "$CN_RESCAN_EVERY" -gt 0 ] && [ $((CN_TICKS % CN_RESCAN_EVERY)) -eq 0 ]; then
        NEW_IFACES="$(
            awk '
                function sanitize(s,   out,c,head,tail) {
                    out=""
                    for (i=1;i<=length(s);i++) {
                        c=substr(s,i,1)
                        if (c>="A" && c<="Z") c=tolower(c)
                        out=out c
                    }
                    s=out
                    gsub(/[^a-z0-9]/, "_", s)
                    gsub(/_+/, "_", s)
                    sub(/^_/, "", s)
                    sub(/_$/, "", s)
                    if (length(s) <= 20) return s
                    head=substr(s,1,8)
                    tail=substr(s,length(s)-11,12)
                    return head tail
                }
                NR>2 {
                    iface=$1; gsub(/:/,"",iface)
                    if (iface=="lo") next
                    id=sanitize(iface)
                    printf("%s %s\n", id, iface)
                }
            ' "$CN_NET_DEV"
        )"
        while IFS= read -r pair; do
            nid=${pair%% *}
            nif=${pair#* }
            case " $CN_KNOWN_IDS " in
                *" $nid "*) : ;;
                *)
                    cn_define_chart "$nid" "$nif"
                    CN_KNOWN_IDS="$CN_KNOWN_IDS $nid"
                    ;;
            esac
        done <<EOF
$NEW_IFACES
EOF
        CN_KNOWN_IDS=$(echo "$CN_KNOWN_IDS" | sed 's/^ *//')
    fi

    return 0
}
