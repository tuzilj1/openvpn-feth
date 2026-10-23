# Test OpenVPN server in dev tap (bridge) mode with a simulated LAN behind it.
# br0 = 10.99.0.1, "LAN device" = network namespace lan with 10.99.0.10, clients get 10.99.0.50-60.
FROM alpine:3.22
RUN apk add --no-cache openvpn iproute2 bridge-utils tcpdump python3 iperf3 iputils
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 1194/tcp
ENTRYPOINT ["/entrypoint.sh"]
