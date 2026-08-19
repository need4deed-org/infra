#!/usr/bin/env bash
# Seal a secret for one cluster. See secrets/README.md and docs/runbooks/sealing-keys.md.
set -euo pipefail

REPO_ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)

TMPFILE=""
trap 'rm -f "$TMPFILE"' EXIT

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage:
  seal-secret.sh fetch-cert <cluster> --context CTX [--force]
  seal-secret.sh seal <cluster> <namespace> <name> --env-file PATH [--force]
  seal-secret.sh seal <cluster> <namespace> <name> --dockerconfigjson PATH [--force]

The plaintext input file must live outside this repo.
EOF
  exit 2
}

require_tools() {
  command -v kubeseal >/dev/null \
    || die "kubeseal is not on PATH. Install the pinned release: see docs/runbooks/sealing-keys.md"
  command -v openssl >/dev/null || die "openssl is not on PATH"
}

cert_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

# Names land in file paths as well as in Kubernetes objects.
check_name() {
  [[ $2 =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "$1 '$2' is not a DNS-1123 label"
}

# A gitignore rule is a weaker guarantee than a refusal.
resolve_outside_repo() {
  local resolved
  resolved=$(realpath -e "$1" 2>/dev/null) || die "no such file: $1"
  [[ $resolved != "$REPO_ROOT"/* ]] \
    || die "plaintext input '$resolved' is inside the repo. Keep it outside the worktree."
  echo "$resolved"
}

cmd_fetch_cert() {
  local cluster=${1:-}
  [ -n "$cluster" ] || usage
  shift
  local context="" force=0
  while [ $# -gt 0 ]; do
    case $1 in
      --context) [ -n "${2:-}" ] || usage; context=$2; shift 2 ;;
      --force) force=1; shift ;;
      *) usage ;;
    esac
  done
  check_name cluster "$cluster"
  # Nothing else ties <cluster> to the cluster the cert comes from, so make the
  # operator name both and put them side by side in the output.
  [ -n "$context" ] || die "--context is required: <cluster> is a directory name, not a target"
  require_tools

  local out="$REPO_ROOT/secrets/$cluster/pub-cert.pem"
  mkdir -p "$(dirname "$out")"
  TMPFILE="$out.tmp"
  kubeseal --fetch-cert --context "$context" > "$TMPFILE"

  if [ -e "$out" ] && [ "$force" != 1 ]; then
    echo "$out exists" >&2
    echo "  on disk:  $(cert_fp "$out")" >&2
    echo "  fetched:  $(cert_fp "$TMPFILE")  (context $context)" >&2
    die "replacing it re-points every future seal for '$cluster'. Re-fetch with --force."
  fi
  mv "$TMPFILE" "$out"

  echo "wrote $out"
  echo "  cert sha256: $(cert_fp "$out")"
  echo "  from context: $context"
  echo "Commit it: the cert is public, and it records which key a blob was sealed against."
}

cmd_seal() {
  # Sealing is fully offline: kubectl runs --dry-run=client and kubeseal
  # encrypts against the committed cert. Detach from any kubeconfig so a
  # root-only /etc/rancher/k3s/k3s.yaml does not fail the client-side render.
  export KUBECONFIG=/dev/null
  [ $# -ge 3 ] || usage
  local cluster=$1 namespace=$2 name=$3
  shift 3
  local env_file="" dockerconfig="" force=0
  while [ $# -gt 0 ]; do
    case $1 in
      --env-file) [ -n "${2:-}" ] || usage; env_file=$2; shift 2 ;;
      --dockerconfigjson) [ -n "${2:-}" ] || usage; dockerconfig=$2; shift 2 ;;
      --force) force=1; shift ;;
      *) usage ;;
    esac
  done
  check_name cluster "$cluster"
  check_name namespace "$namespace"
  check_name name "$name"
  [ -n "$env_file$dockerconfig" ] || die "one of --env-file / --dockerconfigjson is required"
  [ -z "$env_file" ] || [ -z "$dockerconfig" ] || die "--env-file and --dockerconfigjson are mutually exclusive"
  require_tools

  local cert="$REPO_ROOT/secrets/$cluster/pub-cert.pem"
  [ -f "$cert" ] || die "no cert at $cert. Run: seal-secret.sh fetch-cert $cluster --context <ctx>"

  local out="$REPO_ROOT/secrets/$cluster/$namespace/$name.yaml"
  [ ! -e "$out" ] || [ "$force" = 1 ] || die "$out exists. Re-seal with --force."

  # Plaintext stays inside the pipe: never in argv, never on disk in the repo.
  local src
  local -a create=(kubectl create secret generic "$name" --namespace "$namespace")
  if [ -n "$env_file" ]; then
    src=$(resolve_outside_repo "$env_file")
    create+=(--from-env-file "$src")
  else
    src=$(resolve_outside_repo "$dockerconfig")
    create+=(--type kubernetes.io/dockerconfigjson --from-file ".dockerconfigjson=$src")
  fi

  mkdir -p "$(dirname "$out")"
  TMPFILE="$out.tmp"
  # In a variable, not a file: plaintext still never touches disk.
  local rendered
  rendered=$("${create[@]}" --dry-run=client -o yaml)
  printf '%s\n' "$rendered" \
    | kubeseal --cert "$cert" --format yaml --scope strict > "$TMPFILE"
  mv "$TMPFILE" "$out"

  echo "wrote $out"
  echo "  cert sha256: $(cert_fp "$cert")"
  # --from-env-file is a literal parser: it keeps quotes, trailing spaces and a
  # literal \n. Nothing downstream compares the sealed value to its source, so
  # the byte counts are the only chance to catch it before the commit.
  while read -r key b64; do
    printf '  %-30s %s bytes\n' "$key" "$(printf '%s' "$b64" | base64 -d | wc -c)"
  done < <(printf '%s\n' "$rendered" \
    | awk '/^data:/{d=1;next} d&&/^[^ ]/{d=0} d&&/^  /{sub(/:$/,"",$1); gsub(/"/,"",$2); print $1, $2}')
  echo ""
  echo "Still owed:"
  echo "  1. add $name.yaml to secrets/$cluster/$namespace/kustomization.yaml"
  echo "  2. include ../../secrets/$cluster/$namespace from the overlay that deploys to $cluster"
}

case ${1:-} in
  fetch-cert) shift; cmd_fetch_cert "$@" ;;
  seal)       shift; cmd_seal "$@" ;;
  *)          usage ;;
esac
