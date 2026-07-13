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

echo "=== 1/4  Installing k3s ==="
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE=644 sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== 2/4  Waiting for node to be Ready ==="
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  printf '.'; sleep 3
done
echo ""

echo "=== 3/4  Configuring Traefik for Let's Encrypt ==="
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

echo "=== 4/4  Cloning infra repo ==="
sudo git clone "$INFRA_REPO" "$INFRA_DIR"
sudo chown -R "$USER:$USER" "$INFRA_DIR"

echo ""
echo "=================================================================="
echo "Bootstrap complete."
echo ""
echo "Secrets and manifests are managed by the deploy-dev CI workflow."
echo "Trigger it from GitHub to apply secrets and deploy all resources:"
echo ""
echo "  https://github.com/need4deed-org/infra/actions/workflows/deploy.yaml"
echo ""
echo "Before triggering, ensure these GitHub Actions secrets are set"
echo "in the infra repo (Settings → Secrets and variables → Actions):"
echo ""
echo "  AITS_HOST            — VPS IP or hostname"
echo "  AITS_SSH_KEY         — private SSH key for ubuntu@<host>"
echo "  DB_PASSWORD          — postgres n4d user password"
echo "  JWT_SECRET           — JWT signing secret"
echo "  SMTP_PASS            — Infomaniak verify SMTP password"
echo "  SMTP_NOTIFY_PASS     — Infomaniak notify SMTP password"
echo "  BREVO_API_KEY        — Brevo API key"
echo "  SLACK_OPS_WEBHOOK_URL"
echo "  SLACK_COMMENTS_WEBHOOK_URL"
echo ""
echo "DNS: add an A record  aits.need4deed.org → $(curl -sf ifconfig.me || hostname -I | awk '{print $1}')"
echo "=================================================================="
