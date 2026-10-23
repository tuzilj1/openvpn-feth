#!/bin/bash
# End-to-end L2 test over feth: Mac (patched OpenVPN) <-> container openvpn-feth-srv (dev tap, bridge) <-> LAN host 10.99.0.10.
# Usage: run-tests.sh <path to openvpn> <PKI directory from make-pki.sh> [extra openvpn arguments, e.g. --dev-node feth]
set -uo pipefail
OVPN="${1:?openvpn}"; PKI="${2:?pki}"; shift 2
EXTRA=("$@")
WORK="$(mktemp -d)"
LAN=(docker exec openvpn-feth-srv ip netns exec lan)
PASS=0; FAIL=0
ok()   { echo "  OK    $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

start_client() { # $1 = instance name
    ( cd "$PKI" && exec sudo -n "$OVPN" --config client.ovpn ${EXTRA[@]+"${EXTRA[@]}"} --writepid "$WORK/$1.pid" ) \
        < /dev/null > "$WORK/$1.log" 2>&1 &
    for _ in $(seq 1 30); do
        grep -q "Initialization Sequence Completed" "$WORK/$1.log" 2>/dev/null && break
        sleep 0.5
    done
    grep -oE 'TUN/TAP device (/dev/)?[a-z0-9]+ opened' "$WORK/$1.log" | awk '{sub("/dev/", "", $3); print $3}'
}
stop_client() { sudo -n kill -TERM "$(sudo -n cat "$WORK/$1.pid")" 2>/dev/null; sleep 2; }
ip_of() { ifconfig "$1" | awk '/inet /{print $2}'; }

echo "== T1 connect"
IF1="$(start_client c1)"
if [[ -n "$IF1" ]] && grep -q "Initialization Sequence Completed" "$WORK/c1.log"; then ok "connected, interface $IF1"; else bad "connect"; tail -20 "$WORK/c1.log"; exit 1; fi
IP1="$(ip_of "$IF1")"; MAC1="$(ifconfig "$IF1" | awk '/ether/{print $2}')"
[[ "$IP1" == 10.99.0.* ]] && ok "pushed IP: $IP1" || bad "IP: '$IP1'"
[[ "$MAC1" != 66:65:74:68:* ]] && ok "random MAC $MAC1" || bad "MAC is the deterministic feth MAC $MAC1"

echo "== T2 unicast + ARP"
ping -c 3 -t 5 -q 10.99.0.10 > /dev/null && ok "ping 10.99.0.10 (LAN host behind the bridge)" || bad "ping LAN host"
"${LAN[@]}" ip neigh show "$IP1" | grep -qi "$MAC1" && ok "LAN host learned the client MAC via ARP" || bad "ARP on the LAN side"

echo "== T3 broadcast LAN -> Mac (UDP 47808, BACnet/IP)"
python3 -c '
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("0.0.0.0",47808)); s.settimeout(6)
try: d,a=s.recvfrom(100); print(d.decode(), a[0])
except socket.timeout: print("timeout")' > "$WORK/bc1.txt" &
sleep 1
"${LAN[@]}" python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
for _ in range(3): s.sendto(b"who-is", ("10.99.0.255",47808))'
wait
grep -q "who-is 10.99.0.10" "$WORK/bc1.txt" && ok "broadcast received on the Mac" || bad "broadcast LAN->Mac: $(command cat "$WORK/bc1.txt")"

echo "== T4 broadcast Mac -> LAN (UDP 47809)"
"${LAN[@]}" timeout 6 python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("0.0.0.0",47809))
d,a=s.recvfrom(100); print(d.decode(), a[0])' > "$WORK/bc2.txt" &
sleep 1.5
python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
for _ in range(3): s.sendto(b"i-am", ("10.99.0.255",47809))'
wait
grep -q "i-am $IP1" "$WORK/bc2.txt" && ok "broadcast received in the LAN" || bad "broadcast Mac->LAN: $(command cat "$WORK/bc2.txt")"

echo "== T5 multicast LAN -> Mac (224.0.23.12:3671, KNXnet/IP)"
sudo -n tcpdump -n -l -c 1 -i "$IF1" "dst host 224.0.23.12" > "$WORK/mc.txt" 2>/dev/null &
TD=$!; sleep 1.5
"${LAN[@]}" python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IP,socket.IP_MULTICAST_IF,socket.inet_aton("10.99.0.10"))
for _ in range(3): s.sendto(b"knx", ("224.0.23.12",3671))'
sleep 1.5; sudo -n kill "$TD" 2>/dev/null; wait "$TD" 2>/dev/null
grep -q "224.0.23.12" "$WORK/mc.txt" && ok "multicast frame arrived on $IF1" || bad "multicast"

echo "== T6 raw L2 frame (ethertype 0x88b5, non-IP) LAN -> Mac"
sudo -n tcpdump -n -l -e -c 1 -i "$IF1" "ether proto 0x88b5" > "$WORK/l2a.txt" 2>/dev/null &
TD=$!; sleep 1.5
"${LAN[@]}" python3 -c '
import socket
s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW); s.bind(("veth-lan",0))
src=s.getsockname()[4]
for _ in range(3): s.send(b"\xff"*6+src+b"\x88\xb5"+b"raw-l2-test".ljust(46,b"\0"))'
sleep 1.5; sudo -n kill "$TD" 2>/dev/null; wait "$TD" 2>/dev/null
grep -q "0x88b5" "$WORK/l2a.txt" && ok "non-IP broadcast frame arrived on the Mac" || bad "L2 LAN->Mac"

echo "== T7 raw L2 frame Mac -> LAN (written via BPF on $IF1)"
"${LAN[@]}" timeout 6 tcpdump -n -l -e -c 1 -i veth-lan "ether proto 0x88b5" > "$WORK/l2b.txt" 2>/dev/null &
sleep 1.5
sudo -n python3 - "$IF1" "$MAC1" <<'EOF'
import fcntl, os, struct, sys
ifn, mac = sys.argv[1], bytes.fromhex(sys.argv[2].replace(":", ""))
for i in range(256):
    try: fd = os.open(f"/dev/bpf{i}", os.O_RDWR); break
    except OSError: pass
BIOCSETIF = 0x8020426c
fcntl.ioctl(fd, BIOCSETIF, struct.pack("16s16x", ifn.encode()))
for _ in range(3): os.write(fd, b"\xff"*6 + mac + b"\x88\xb5" + b"raw-from-mac".ljust(46, b"\0"))
EOF
wait
grep -q "0x88b5" "$WORK/l2b.txt" && ok "non-IP frame from the Mac arrived in the LAN" || bad "L2 Mac->LAN"

echo "== T8 throughput (iperf3 5 s, TCP through the tunnel)"
UP="$(iperf3 -c 10.99.0.10 -t 5 -J 2>/dev/null | python3 -c 'import json,sys; print(round(json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"]/1e6))' 2>/dev/null)"
DN="$(iperf3 -c 10.99.0.10 -t 5 -R -J 2>/dev/null | python3 -c 'import json,sys; print(round(json.load(sys.stdin)["end"]["sum_received"]["bits_per_second"]/1e6))' 2>/dev/null)"
[[ -n "$UP" && -n "$DN" ]] && ok "upload ${UP} Mbit/s, download ${DN} Mbit/s" || bad "iperf3 (up='$UP' down='$DN')"

echo "== T9 change the IP address with ifconfig"
sudo -n /sbin/ifconfig "$IF1" 10.99.0.77 netmask 255.255.255.0
ping -c 3 -t 5 -q 10.99.0.10 > /dev/null && ok "ping works after changing the IP to 10.99.0.77" || bad "ping after IP change"

echo "== T10 second connection at the same time"
IF2="$(start_client c2)"
if [[ -n "$IF2" && "$IF2" != "$IF1" ]]; then
    IP2="$(ip_of "$IF2")"; MAC2="$(ifconfig "$IF2" | awk '/ether/{print $2}')"
    ok "second connection on $IF2 ($IP2, $MAC2)"
    # Both connections are in the same subnet, so a ping from the Mac would use the first interface.
    # The second tunnel is checked from the LAN: ARP for IP2 must return the MAC of the second interface.
    "${LAN[@]}" arping -c 2 -w 4 -I veth-lan "$IP2" > "$WORK/arp2.txt" 2>&1
    grep -qi "$MAC2" "$WORK/arp2.txt" && ok "LAN reaches $IF2 (ARP $IP2 -> $MAC2)" || bad "ARP on $IF2: $(command cat "$WORK/arp2.txt")"
    [[ "$MAC2" != "$MAC1" ]] && ok "each connection has its own MAC" || bad "both connections have the same MAC"
    stop_client c2
else
    bad "second connection: $(tail -5 "$WORK/c2.log")"
fi

echo "== T11 disconnect and clean-up"
stop_client c1
grep -q "SIGTERM\[hard,\] received" "$WORK/c1.log" && ok "OpenVPN exited" || bad "exit"
ifconfig -l | tr ' ' '\n' | grep -q '^feth' && bad "feth interfaces left behind: $(ifconfig -l)" || ok "feth interfaces removed"
grep -E "feth|WARN|ERROR" "$WORK/c1.log" | grep -v "^$" | sed 's/^/        log: /'

if [[ "$IF1" == feth* ]]; then
    echo "== T12 OpenVPN crash (kill -9) and clean-up on the next start"
    IFK="$(start_client k1)"
    sudo -n kill -9 "$(sudo -n cat "$WORK/k1.pid")"; sleep 1
    ifconfig "$IFK" > /dev/null 2>&1 && ok "$IFK left behind after kill -9 (expected)" || bad "interface gone after kill -9?"
    IFK2="$(start_client k2)"
    grep -q "removing stale pair $IFK/" "$WORK/k2.log" && ok "next start removed the orphaned pair" || bad "orphaned pair not removed"
    ping -c 2 -t 5 -q 10.99.0.10 > /dev/null && ok "new connection on $IFK2 works" || bad "ping after clean-up"
    stop_client k2
    ifconfig -l | tr ' ' '\n' | grep -q '^feth' && bad "feth interfaces left behind: $(ifconfig -l)" || ok "feth interfaces removed"
fi

echo "== Result: $PASS OK, $FAIL FAIL (logs in $WORK)"
[[ $FAIL -eq 0 ]]
