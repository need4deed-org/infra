# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kubernetes (k3s) infrastructure for the Need4Deed platform, managed with kustomize.
This replaced the old Terraform/AWS setup (`n4d-infra`, now legacy — see that repo's
CLAUDE.md) after the 2026 AWS → Infomaniak migration. Details of the migration
itself are in `aws-to-infomaniak-migration.md`.

**Production and dev/pre are on different physical machines:**

| Environment | Host | Namespace | Postgres | Domain |
|---|---|---|---|---|
| prod | Infomaniak VPS (dedicated) | `n4d-prod` | in-cluster StatefulSet + pgBackRest | `app.need4deed.org` |
| dev / pre | AITS VPS (shared, `aits.need4deed.org`) | `n4d-dev` | in-cluster StatefulSet | `aits.need4deed.org` |

### Production VPS

- IPv4 `179.237.108.234`, IPv6 `2001:1600:18:209::116`
- 4 vCPU / 12 GB RAM / 250 GB disk, Infomaniak, unmanaged
- SSH: `ssh ubuntu@179.237.108.234` (key-only)
- Runs k3s single-node; `kubectl` needs `sudo` (kubeconfig is root-only)

Full day-to-day operator guide (SSH access, kubectl helpers, database access,
deploying a new fe/be version, secrets, troubleshooting) is in
**`docs/dev-guide.md` — read that before operating on prod**, this file only
orients you to the repo layout.

## Website (`need4deed.org`)

`need4deed.org` (apex/www) is **not** part of this repo's ingress yet — it's the
separate `website` repo, still deployed on **AWS Amplify**, unmigrated. That's why
`overlays/prod/ingress.yaml` only routes `app.need4deed.org` and has a comment
explaining the apex/www are deliberately left out (routing them here before DNS
moves would just generate failing ACME challenges against Let's Encrypt's rate
limits).

**Planned to change within weeks:** `website` is being ditched entirely — its
content will move to live at the `app.need4deed.org` home page instead of a
separate site/deploy. When that lands, expect `overlays/prod/ingress.yaml` to
gain rules for `need4deed.org`/`www.need4deed.org` pointing at the `fe` service,
and `website`/Amplify to go away. Check whether this has already happened before
planning work around the current apex-on-Amplify split.

## Repo layout

```
base/                    # shared manifests: be, fe, cdn-proxy, network-policies
  be/ fe/ cdn-proxy/ network-policies/ workers/(not wired in yet)
components/               # kustomize components, opted into by overlays
  postgres/                # in-cluster Postgres StatefulSet + Service
  postgres-prod/           # patches on top of postgres/: backups, TLS, pg_hba, alerts
overlays/
  dev/                     # deploys to AITS, namespace n4d-dev
  prod/                    # deploys to the Infomaniak prod VPS, namespace n4d-prod
  dress-rehearsal/         # exercises a full restore against prod-shaped data
  restore-rehearsal/       # DB-restore drill namespace
cluster/sealed-secrets/   # SealedSecrets controller, installed by bootstrap.sh
secrets/<cluster>/<namespace>/<name>.yaml   # sealed (ciphertext) secrets, safe to commit
scripts/                  # bootstrap.sh, seal-secret.sh, gen-postgres-tls.sh, prod-checks.sh
docs/dev-guide.md          # operator runbook (read before touching prod)
docs/runbooks/             # db-restore.md, sealing-keys.md
```

Every environment is `../../base` plus overlay-specific patches/components — there
is no environment-specific fork of the app manifests themselves.

## Images and deploys

Every image (`be`, `fe`, `bootstrap`, `postgres`) is pinned **by digest** in
`overlays/<env>/kustomization.yaml`. Merging code doesn't change what's running —
production only changes when a digest pin changes and that change is applied.
`release-prod.yaml` (manual `workflow_dispatch`) builds fresh fe/bootstrap images,
resolves be's current `develop` digest, and opens a PR bumping the three pins in
`overlays/prod/kustomization.yaml` — merging that PR does **not** deploy it; the
actual deploy is still a manual `git pull && kubectl apply -k overlays/prod/` on
the prod VPS (see `docs/dev-guide.md`). `deploy.yaml` auto-deploys `overlays/dev/`
to AITS on every push to `main`.

Rollback is reverting the pin commit and re-applying — it does **not** undo a
database migration the reverted image already ran.

## Secrets

Managed as **SealedSecrets** — ciphertext committed under `secrets/<cluster>/<namespace>/`,
decryptable only by the cluster they were sealed against. Git and CI only ever see
ciphertext. To add/rotate one: `scripts/seal-secret.sh` against a plaintext file kept
**outside** this repo, then commit the sealed blob and include it from the deploying
overlay's kustomization. Full procedure: `secrets/README.md` and
`docs/runbooks/sealing-keys.md`. `n4d-dev` on AITS is not yet sealed (still raw
`kubectl create secret --from-literal` in `deploy.yaml`'s CI step) — don't assume dev
secrets are protected the same way as prod's.

## Common commands (on the target VPS, not locally)

```bash
git -C /opt/infra pull
kubectl diff -k /opt/infra/overlays/<env>      # review before applying, always
kubectl apply -k /opt/infra/overlays/<env>
kubectl get pods -w
```

Fresh VPS bootstrap (installs k3s + Traefik + SealedSecrets controller):

```bash
bash scripts/bootstrap.sh   # env vars override AITS/dev defaults for prod, see script header
```

## Key conventions

- **Never hand-edit cluster state directly** — every change goes through a manifest
  in this repo, applied via `kubectl apply -k`. An empty `kubectl diff` after apply
  is the definition of "deployed".
- **Never commit a plaintext secret** — only sealed blobs under `secrets/`.
- **Managed Postgres vs in-cluster Postgres**: unlike the original AWS-migration
  plan, prod runs Postgres **in-cluster** (`components/postgres` + `components/postgres-prod`),
  not an Infomaniak managed database — an overlay that used a managed DB would omit
  both components instead.
- Digest pins in `overlays/prod/kustomization.yaml` are the source of truth for
  "what is prod running" — check there before assuming a merged PR is live.
