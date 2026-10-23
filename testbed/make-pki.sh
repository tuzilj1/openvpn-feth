#!/bin/bash
# Generates a test CA, server and client certificates and the configurations into directory $1.
set -euo pipefail
OUT="${1:?target directory}"
mkdir -p "$OUT"
cd "$OUT"
OSSL="${OPENSSL:-openssl}"   # needs OpenSSL 3 (not LibreSSL), e.g. OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl

$OSSL req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
    -keyout ca.key -out ca.crt -subj "/CN=feth-test-ca" 2>/dev/null

issue() { # $1 = name, $2 = extendedKeyUsage
    $OSSL req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$1.key" -out "$1.csr" -subj "/CN=$1" 2>/dev/null
    printf 'extendedKeyUsage=%s\nkeyUsage=digitalSignature,keyAgreement\n' "$2" > "$1.ext"
    $OSSL x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 \
        -extfile "$1.ext" -out "$1.crt" 2>/dev/null
    rm -f "$1.csr" "$1.ext"
}
issue server serverAuth
issue client clientAuth

cat > server.conf <<'EOF'
port 1194
proto tcp-server
mode server
tls-server
dev tap0
ca /pki/ca.crt
cert /pki/server.crt
key /pki/server.key
dh none
server-bridge 10.99.0.1 255.255.255.0 10.99.0.50 10.99.0.60
duplicate-cn
keepalive 10 60
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
verb 3
EOF

cat > client.ovpn <<'EOF'
tls-client
client
auth-nocache
dev tap
proto tcp
remote 127.0.0.1 1194
resolv-retry infinite
nobind
persist-key
persist-tun
ca ca.crt
cert client.crt
key client.key
remote-cert-tls server
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
connect-retry-max 2
verb 3
EOF
echo "PKI and configurations in $OUT"
