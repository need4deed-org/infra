#!/usr/bin/env bash
# Bootstrap k3s + AITS on a fresh Ubuntu VPS.
# Run as a sudoer: bash bootstrap.sh
set -euo pipefail

# Defaults are AITS/dev-shaped; override via environment for prod, e.g.
#   ACME_EMAIL=admin@need4deed.org INFRA_BRANCH=prod-provisioning \
#   K3S_KUBECONFIG_MODE=600 bash bootstrap.sh
NAMESPACE=${NAMESPACE:-n4d-dev}
ACME_EMAIL=${ACME_EMAIL:-dev@need4deed.org}
INFRA_REPO=${INFRA_REPO:-https://github.com/need4deed-org/infra.git}
INFRA_BRANCH=${INFRA_BRANCH:-main}
INFRA_DIR=${INFRA_DIR:-/opt/infra}
DNS_HINT_HOST=${DNS_HINT_HOST:-aits.need4deed.org}

# 644 lets non-root users call kubectl without sudo; k3s defaults to
# root-only (600). Prod should decide deliberately (sealing-keys.md §7):
# with 644, any local user can read every cluster secret.
K3S_KUBECONFIG_MODE=${K3S_KUBECONFIG_MODE:-644}

# Set K3S_DATA_DIR to move all k3s state (containerd images, local-path
# volumes, auto-deploy manifests) off the root disk, e.g. to a larger
# data disk: K3S_DATA_DIR=/mnt/data/k3s. Empty keeps the k3s default
# (/var/lib/rancher/k3s).
K3S_DATA_DIR=${K3S_DATA_DIR:-}

echo "=== 1/5  Installing k3s ==="
if [ -n "$K3S_DATA_DIR" ]; then
  curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="$K3S_KUBECONFIG_MODE" \
    INSTALL_K3S_EXEC="server --data-dir $K3S_DATA_DIR" sh -
else
  curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="$K3S_KUBECONFIG_MODE" sh -
fi
MANIFESTS_DIR="${K3S_DATA_DIR:-/var/lib/rancher/k3s}/server/manifests"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== 2/5  Waiting for node to be Ready ==="
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  printf '.'; sleep 3
done
echo ""

echo "=== 3/5  Configuring Traefik for Let's Encrypt ==="
# k3s watches its server/manifests directory (relative to the data dir)
# and applies changes automatically.
sudo tee "$MANIFESTS_DIR/traefik-config.yaml" > /dev/null <<EOF
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
  git -C "$INFRA_DIR" fetch origin "$INFRA_BRANCH"
  git -C "$INFRA_DIR" checkout "$INFRA_BRANCH"
  git -C "$INFRA_DIR" pull origin "$INFRA_BRANCH"
else
  sudo git clone -b "$INFRA_BRANCH" "$INFRA_REPO" "$INFRA_DIR"
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
echo "DNS: add an A record  ${DNS_HINT_HOST} → $(curl -sf ifconfig.me || hostname -I | awk '{print $1}')"
echo "=================================================================="
