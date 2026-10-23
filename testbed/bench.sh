#!/bin/bash
# Throughput and retransmissions through the tunnel (iperf3 to the LAN host 10.99.0.10), 3x upload + 3x download.
# Usage: bench.sh <path to openvpn> <PKI directory> [extra openvpn arguments]
set -uo pipefail
OVPN="${1:?openvpn}"; PKI="${2:?pki}"; shift 2
EXTRA=("$@")
WORK="$(mktemp -d)"
( cd "$PKI" && exec sudo -n "$OVPN" --config client.ovpn ${EXTRA[@]+"${EXTRA[@]}"} --writepid "$WORK/pid" ) \
    < /dev/null > "$WORK/log" 2>&1 &
for _ in $(seq 1 30); do grep -q "Initialization Sequence Completed" "$WORK/log" 2>/dev/null && break; sleep 0.5; done
for _ in 1 2 3; do
    for dir in "" "-R"; do
        iperf3 -c 10.99.0.10 -t 4 $dir -J 2>/dev/null | python3 -c "
import json,sys
e=json.load(sys.stdin)['end']
print('download' if '$dir' else 'upload  ', str(round(e['sum_received']['bits_per_second']/1e6)).rjust(5), 'Mbit/s  retransmits', e['sum_sent'].get('retransmits'))"
    done
done
sudo -n kill -TERM "$(sudo -n cat "$WORK/pid")"; sleep 2
grep -E "dropped frames" "$WORK/log"
