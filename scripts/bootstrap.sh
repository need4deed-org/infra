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
# Re-runnable: a second run must reach the controller install below, not abort
# on an existing clone.
if [ -d "$INFRA_DIR/.git" ]; then
  sudo chown -R "$USER:$USER" "$INFRA_DIR"
  git -C "$INFRA_DIR" pull
else
  sudo git clone "$INFRA_REPO" "$INFRA_DIR"
  sudo chown -R "$USER:$USER" "$INFRA_DIR"
fi

echo "=== 5/5  Installing the SealedSecrets controller ==="
# Applied from the repo, not dropped into the k3s auto-deploy directory: that
# channel takes rendered manifests only, which would fork the pinned digest
# away from cluster/sealed-secrets/.
kubectl apply -k "$INFRA_DIR/cluster/sealed-secrets"
# A slow image pull must not abort the script: the key-export instruction below
# is the one message that has to be read.
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s \
  || echo "controller not ready yet. Re-check: kubectl -n kube-system rollout status deploy/sealed-secrets-controller"

echo ""
echo "=================================================================="
echo "Bootstrap complete."
echo ""
echo "DO THIS FIRST. Export the sealing key and put it in the team vault:"
echo ""
echo "  ( umask 077; kubectl get secret -n kube-system \\"
echo "      -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \\"
echo "      > ~/<cluster>-sealing-key.yaml )"
echo ""
echo "The controller has just generated a private key that exists nowhere else."
echo "Lose it and every secret sealed against this cluster is unrecoverable."
echo "Never print it to the terminal, and shred -u the file once it is vaulted."
echo ""
echo "Rebuilding a cluster that already has a vaulted key? Do not export this one."
echo "Restore the vaulted key and delete the one just minted, before sealing"
echo "anything: docs/runbooks/sealing-keys.md section 4."
echo "Full procedure, including the offline verification: docs/runbooks/sealing-keys.md"
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
