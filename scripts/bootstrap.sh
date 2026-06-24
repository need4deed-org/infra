#!/usr/bin/env bash
# Bootstrap k3s + AITS on a fresh Ubuntu VPS.
# Run as a sudoer: bash bootstrap.sh
set -euo pipefail

NAMESPACE=n4d-dev
ACME_EMAIL=dev@need4deed.org
INFRA_REPO=https://github.com/need4deed-org/infra.git
INFRA_DIR=/opt/infra

# Allow non-root users to call kubectl without sudo.
# k3s writes its kubeconfig as root-only by default; this makes it world-readable.
K3S_KUBECONFIG_MODE=644

echo "=== 1/5  Installing k3s ==="
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE=644 sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== 2/5  Waiting for node to be Ready ==="
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  printf '.'; sleep 3
done
echo ""

echo "=== 3/5  Configuring Traefik for Let's Encrypt ==="
# k3s watches /var/lib/rancher/k3s/server/manifests/ and applies changes automatically.
sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml > /dev/null <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    additionalArguments:
      - "--certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.tlschallenge=true"
    persistence:
      enabled: true
      size: 128Mi
EOF

echo "=== 4/5  Cloning infra repo ==="
sudo git clone "$INFRA_REPO" "$INFRA_DIR"
sudo chown -R "$USER:$USER" "$INFRA_DIR"

echo "=== 5/5  Creating namespace ==="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=================================================================="
echo "Bootstrap complete. Before running 'kubectl apply -k overlays/dev/',"
echo "create the two secrets below (fill in real values):"
echo ""
echo "kubectl create secret generic postgres-secret -n $NAMESPACE \\"
echo "  --from-literal=POSTGRES_DB=n4d \\"
echo "  --from-literal=POSTGRES_USER=n4d \\"
echo "  --from-literal=POSTGRES_PASSWORD=<CHANGE_ME>"
echo ""
echo "kubectl create secret generic be-secret -n $NAMESPACE \\"
echo "  --from-literal=DB_HOST=postgres \\"
echo "  --from-literal=DB_PORT=5432 \\"
echo "  --from-literal=DB_USER=n4d \\"
echo "  --from-literal=DB_PASSWORD=<CHANGE_ME> \\"
echo "  --from-literal=DB_NAME=n4d \\"
echo "  --from-literal=DB_SCHEMA=public \\"
echo "  --from-literal=JWT_SECRET=<CHANGE_ME> \\"
echo "  --from-literal=NODE_ENV=development \\"
echo "  --from-literal=RUN_MIGRATIONS=true \\"
echo "  --from-literal=CORS_ORIGINS=<comma-separated-allowed-origins> \\"
echo "  --from-literal=EMAIL_FROM=<sender-address> \\"
echo "  --from-literal=BREVO_API_KEY=<CHANGE_ME>"
echo ""
echo "If the ghcr.io package is private, also create an image pull secret:"
echo "kubectl create secret docker-registry ghcr-secret -n $NAMESPACE \\"
echo "  --docker-server=ghcr.io \\"
echo "  --docker-username=<github-username> \\"
echo "  --docker-password=<github-pat-with-read-packages>"
echo "(Then uncomment imagePullSecrets in base/be/deployment.yaml)"
echo ""
echo "DNS: add an A record  aits.need4deed.org → $(curl -sf ifconfig.me || hostname -I | awk '{print $1}')"
echo ""
echo "Then apply manifests:"
echo "  cd $INFRA_DIR && kubectl apply -k overlays/dev/"
echo "=================================================================="
