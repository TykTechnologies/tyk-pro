#!/bin/sh
# Generates the test CA trusted by the `tyk` gateway (SSL_CERT_DIR=/etc/tyk-test-ca) and the
# mcp-tls certificate nginx serves in front of mcp-server. The MCP OAuth broker only accepts
# HTTPS upstreams (plain HTTP is limited to loopback), so the broker tests reach the mock as
# https://mcp-tls. The CA key is not kept; rerun this script to rotate all three files.
set -eu
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
O = Tyk test
CN = Tyk test CA
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat >"$tmp/leaf.cnf" <<'EOF'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:mcp-tls
EOF

mkdir -p test-ca
openssl req -x509 -newkey rsa:2048 -nodes -days 9000 -config "$tmp/ca.cnf" \
  -keyout "$tmp/ca.key" -out test-ca/ca.crt
openssl req -newkey rsa:2048 -nodes -subj "/O=Tyk test/CN=mcp-tls" \
  -keyout mcp-tls.key -out "$tmp/leaf.csr"
openssl x509 -req -in "$tmp/leaf.csr" -CA test-ca/ca.crt -CAkey "$tmp/ca.key" -CAserial "$tmp/ca.srl" -CAcreateserial \
  -days 9000 -extfile "$tmp/leaf.cnf" -out mcp-tls.crt
