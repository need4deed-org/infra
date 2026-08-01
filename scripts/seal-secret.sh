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
  seal-secret.sh fetch-cert <cluster> [--context CTX]
  seal-secret.sh seal <cluster> <namespace> <name> --env-file PATH [--force]
  seal-secret.sh seal <cluster> <namespace> <name> --dockerconfigjson PATH [--force]

The plaintext input file must live outside this repo.
EOF
  exit 2
}

require_kubeseal() {
  command -v kubeseal >/dev/null \
    || die "kubeseal is not on PATH. Install the pinned release: see docs/runbooks/sealing-keys.md"
}

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
  local -a ctx=()
  while [ $# -gt 0 ]; do
    case $1 in
      --context) [ -n "${2:-}" ] || usage; ctx=(--context "$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  check_name cluster "$cluster"
  require_kubeseal

  local out="$REPO_ROOT/secrets/$cluster/pub-cert.pem"
  mkdir -p "$(dirname "$out")"
  TMPFILE="$out.tmp"
  kubeseal --fetch-cert "${ctx[@]}" > "$TMPFILE"
  mv "$TMPFILE" "$out"

  echo "wrote $out"
  echo "Commit it: the cert is public, and it records which key a blob was sealed against."
}

cmd_seal() {
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
  require_kubeseal

  local cert="$REPO_ROOT/secrets/$cluster/pub-cert.pem"
  [ -f "$cert" ] || die "no cert at $cert. Run: seal-secret.sh fetch-cert $cluster"

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
  "${create[@]}" --dry-run=client -o yaml \
    | kubeseal --cert "$cert" --format yaml --scope strict > "$TMPFILE"
  mv "$TMPFILE" "$out"

  echo "wrote $out"
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
