#!/bin/sh
# Bridge br0 = tap0 (OpenVPN) + veth into the namespace lan (a device in the remote LAN).
set -eu

ip link add br0 type bridge
ip addr add 10.99.0.1/24 dev br0
ip link set br0 up

ip netns add lan
ip link add veth-br type veth peer name veth-lan
ip link set veth-lan netns lan
ip link set veth-br master br0 up
ip netns exec lan ip addr add 10.99.0.10/24 dev veth-lan
ip netns exec lan ip link set veth-lan up
ip netns exec lan ip link set lo up
# iperf3 server on the "LAN device"
ip netns exec lan iperf3 -s -D

openvpn --mktun --dev tap0
ip link set tap0 master br0 up

exec openvpn --config /pki/server.conf
