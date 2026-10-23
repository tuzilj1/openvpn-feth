# openvpn-feth: OpenVPN `dev tap` on macOS without a kernel extension

A patch for **OpenVPN 2.6.17** that runs bridged (layer 2, `dev tap`) OpenVPN connections on macOS
without the tap kernel extension (tuntaposx / Tunnelblick kext). Instead of `/dev/tapN` it uses a
pair of the built-in virtual Ethernet interfaces `feth(4)`, the same approach ZeroTier uses. The
server side does not change.

- No kext, no Reduced Security on Apple Silicon, no approval in System Settings, no reboot.
- Needs only root, which OpenVPN needs anyway to configure interfaces.
- Unicast, ARP, broadcast, multicast and non-IP Ethernet frames work in both directions.

This is the OpenVPN binary bundled with the SSI Remote Access macOS app by SAFECONTROL s.r.o. The
repository is the corresponding source required by the GPL. It is not affiliated with or endorsed
by OpenVPN Inc. "OpenVPN" is a trademark of OpenVPN Inc.

## How it works

```
macOS network stack <-> feth0 (visible, gets the pushed IP) <-peer-> feth1 <-> OpenVPN
```

- **OS to VPN:** frames macOS sends out of `feth0` appear on `feth1`, where OpenVPN captures them with
  BPF (`/dev/bpfN`). A reader thread splits BPF buffers into single frames and passes them over a
  datagram socketpair, so OpenVPN's event loop sees a descriptor that behaves like a tap device
  (one frame per `read`).
- **VPN to OS:** frames are sent out of `feth1` with an `AF_NDRV` socket and macOS receives them on
  `feth0`.
- **MAC address:** feth interfaces have deterministic MACs (`66:65:74:68:00:0N`, "feth" + number), so
  two Macs in one bridged LAN would collide. A random locally administered MAC is set instead.
- **Clean-up after a crash:** unlike `/dev/tapN`, feth interfaces survive the process (`kill -9`)
  including their IP and routes. Ownership of each pair is recorded in
  `/var/run/openvpn-feth/<interface>` (PID and peer) and every start removes pairs whose process is
  gone.
- The number of dropped frames is logged on close.

The change is limited to `src/openvpn/tun.c` (Darwin branch) and one pointer in `struct tuntap` in
`tun.h`, about 440 lines.

### When feth is used

- `dev tap` with `dev-node feth` (or `--dev-node feth`) always uses feth.
- `dev tap` without `dev-node` uses feth when the tap kext is not loaded (`/dev/tap0` does not
  exist). With the kext loaded, the behaviour is unchanged.
- `dev tun` (utun) is not affected.

The log shows `TUN/TAP device feth0 opened (feth tap emulation, peer feth1)`. If the pair cannot be
created, OpenVPN exits with `Cannot open feth tap emulation`.

## Building

Requirements: macOS on Apple Silicon, Xcode command line tools, `gpg`.

```bash
./build.sh                    # work directory /tmp/openvpn-feth
# result: /tmp/openvpn-feth/build/src/openvpn/openvpn
```

`build.sh` downloads OpenVPN 2.6.17, OpenSSL 3.5.9, LZO 2.10 and LZ4 1.10.0, verifies them with
SHA-256 (OpenVPN also with its GPG signature), builds the libraries statically, applies the patch
and builds OpenVPN. The binary links only `/usr/lib/libSystem` and `libresolv`; the script fails if
it links anything else. PKCS#11 and the plugins are disabled. The build targets arm64 and macOS 13
or newer; it is tested on current macOS (27) only.

The build is not bit-for-bit reproducible (build paths and the Mach-O UUID end up in the binary).

## Releases

Each release contains the exact binary shipped in the app, its SHA-256 and the unmodified source
archives it was built from, so the source stays available even if an upstream download disappears.

## Testing

`testbed/` contains an OpenVPN server in bridge mode in a Docker container (`dev tap0` in bridge
`br0`) with a simulated LAN host (network namespace, 10.99.0.10), and an end-to-end test script.

```bash
testbed/make-pki.sh /tmp/openvpn-feth/pki      # needs OpenSSL 3: OPENSSL=/path/to/openssl
docker build -t openvpn-feth-testbed testbed
docker run -d --name openvpn-feth-srv --privileged --device /dev/net/tun -p 1194:1194 \
    -v /tmp/openvpn-feth/pki:/pki:ro openvpn-feth-testbed
testbed/run-tests.sh /tmp/openvpn-feth/build/src/openvpn/openvpn /tmp/openvpn-feth/pki --dev-node feth
testbed/bench.sh /tmp/openvpn-feth/build/src/openvpn/openvpn /tmp/openvpn-feth/pki --dev-node feth
docker rm -f openvpn-feth-srv
```

The scripts need passwordless `sudo` (OpenVPN, tcpdump, ifconfig), Docker and iperf3. The container
cannot be restarted with `docker restart` because the entrypoint creates the bridge; recreate it.

| # | Test | feth | tap kext (reference) |
|---|------|------|----------------------|
| T1 | Connect, pushed IP, random MAC | OK | OK |
| T2 | Ping to a LAN host behind the bridge, ARP both ways | OK | OK |
| T3 | UDP broadcast LAN -> Mac (47808, BACnet/IP) | OK | OK |
| T4 | UDP broadcast Mac -> LAN | OK | OK |
| T5 | Multicast LAN -> Mac (224.0.23.12, KNXnet/IP) | OK | OK |
| T6 | Non-IP Ethernet frame (0x88b5) LAN -> Mac | OK | OK |
| T7 | Non-IP Ethernet frame Mac -> LAN | OK | OK |
| T8 | iperf3 throughput | OK | OK |
| T9 | Changing the interface IP with `ifconfig` | OK | OK |
| T10 | Second connection at the same time (own interface, own MAC) | OK | OK |
| T11 | Disconnect, interfaces removed | OK | OK |
| T12 | `kill -9`, next start removes the orphaned pair | OK | – |

Also checked: without the kext the unpatched binary fails with "Cannot allocate TUN/TAP dev
dynamically" while the patched one switches to feth; a SIGUSR1 restart with `persist-tun` keeps the
interface and traffic continues.

Throughput (TCP over a TCP tunnel to a local server, indicative only, macOS 27.2, Apple Silicon):

| | upload | download |
|---|---|---|
| tap kext | 380–545 Mbit/s | ~1630 Mbit/s |
| feth | 315–660 Mbit/s | 800–1610 Mbit/s |

On download feth tops out at roughly 0.8–1.6 Gbit/s; the losses happen on the server (TX drops on
`tap0`) while the client writes into feth. Nothing is dropped on the Mac.

## Limitations

- The feth MTU is at most 1500, so `tun-mtu` above 1500 is not possible.
- If the reader thread stops because of an error (for example someone destroys `feth1` from the
  outside), OpenVPN does not notice and traffic from the OS stops.
- Clean-up after a crash relies on the PID; if the PID is reused, the orphaned pair is removed only
  by a later start.
- Built and tested for arm64 and current macOS only.

## License

OpenVPN is licensed under the GNU General Public License version 2 with the OpenSSL and Apache 2.0
linking exceptions, see [COPYING](COPYING) and [COPYRIGHT.GPL](COPYRIGHT.GPL). The patch and the
scripts in this repository are distributed under the same terms.

The binary also contains, statically linked:

| Component | Version | License |
|-----------|---------|---------|
| OpenSSL | 3.5.9 | Apache License 2.0, [licenses/OpenSSL-LICENSE.txt](licenses/OpenSSL-LICENSE.txt) |
| LZO | 2.10 | GPL-2.0-or-later, [licenses/LZO-COPYING](licenses/LZO-COPYING) |
| LZ4 (library) | 1.10.0 | BSD 2-Clause, [licenses/LZ4-LICENSE](licenses/LZ4-LICENSE) |
