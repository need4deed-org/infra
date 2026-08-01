#!/usr/bin/env bash
# Generate a private CA and a Postgres server certificate for one namespace.
# Key material never enters git: output goes to the gitignored .tls/<namespace>/.
# Usage: bash scripts/gen-postgres-tls.sh <namespace>
set -euo pipefail
# openssl writes the keys at the ambient umask; the chmod below is too late to
# stop anything reading them in the meantime.
umask 077

NAMESPACE="${1:-}"
if ! [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "usage: $0 <namespace>" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/.tls/$NAMESPACE"

if [ -e "$OUT_DIR" ]; then
  echo "$OUT_DIR exists; refusing to overwrite key material" >&2
  exit 1
fi
mkdir -p "$OUT_DIR"

CA_DAYS=3650
CERT_DAYS=825

openssl ecparam -name prime256v1 -genkey -noout -out "$OUT_DIR/ca.key"
openssl req -x509 -new -key "$OUT_DIR/ca.key" -sha256 -days "$CA_DAYS" \
  -subj "/CN=need4deed postgres CA ($NAMESPACE)" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$OUT_DIR/ca.crt"

openssl ecparam -name prime256v1 -genkey -noout -out "$OUT_DIR/tls.key"
openssl req -new -key "$OUT_DIR/tls.key" -subj "/CN=postgres" -out "$OUT_DIR/tls.csr"

# The BE connects to DB_HOST=postgres and node-postgres verifies the hostname,
# so the bare service name has to be a SAN, not just the FQDN.
cat > "$OUT_DIR/tls.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:postgres,DNS:postgres.$NAMESPACE,DNS:postgres.$NAMESPACE.svc,DNS:postgres.$NAMESPACE.svc.cluster.local,DNS:postgres-0.postgres.$NAMESPACE.svc.cluster.local
EXT

openssl x509 -req -in "$OUT_DIR/tls.csr" \
  -CA "$OUT_DIR/ca.crt" -CAkey "$OUT_DIR/ca.key" -CAcreateserial \
  -days "$CERT_DAYS" -sha256 -extfile "$OUT_DIR/tls.ext" \
  -out "$OUT_DIR/tls.crt"

rm -f "$OUT_DIR/tls.csr" "$OUT_DIR/tls.ext" "$OUT_DIR/ca.srl"
chmod 600 "$OUT_DIR/ca.key" "$OUT_DIR/tls.key"

openssl verify -CAfile "$OUT_DIR/ca.crt" "$OUT_DIR/tls.crt"

cat <<MSG

Wrote $OUT_DIR (ca.key stays there; it is the only thing that can reissue).

In prod these two are sealed with kubeseal and committed as SealedSecrets,
not applied by hand. Apply directly only in a scratch namespace:

  kubectl create secret tls postgres-tls -n $NAMESPACE \\
    --cert=$OUT_DIR/tls.crt --key=$OUT_DIR/tls.key

  kubectl create secret generic postgres-ca -n $NAMESPACE \\
    --from-file=ca.crt=$OUT_DIR/ca.crt
MSG
