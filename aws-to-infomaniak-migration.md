# AWS → Infomaniak Migration Plan
_Need4Deed platform — compiled 2026-07-03_

---

## 0. Decisions made / still open

**Decided:**
- **Pre runs on AITS** — the existing dev VPS (`aits.need4deed.org`) hosts both `n4d-dev` and `n4d-pre` as separate k3s namespaces. No separate pre VPS needed. SLA is low (acceptable for a non-prod environment).
- **Pre Postgres** — StatefulSet pod on AITS (same as dev). Each namespace gets its own PVC; no data mixing.
- **Prod Postgres** — Infomaniak managed PostgreSQL (backups, HA, patches handled externally).
- **FE** — separate Deployment in k3s (not collocated with BE).
- **Website images CDN** — Infomaniak Object Storage (`n4d-cdn`, public read) + Infomaniak CDN in front of it. No CloudFront, no Cloudflare. `CLOUDFRONT_URL` in `website/src/config/constants.ts` updated to the Infomaniak CDN URL after provisioning.

**Still open:**
- [ ] **Object Storage S3 compatibility** — check whether `be` uses the AWS SDK directly or a generic S3 client. If AWS SDK, only `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET` env vars need changing.
- [ ] **Check AITS headroom** before adding pre — run `kubectl top nodes` and `free -h` on AITS to confirm it can carry two full stacks (two BE pods, two Postgres pods, two FE pods, two website pods).

---

## 1. Infrastructure layout (target state)

| Environment | Host | Postgres | Domain |
|---|---|---|---|
| dev | AITS VPS (`n4d-dev` namespace) | StatefulSet pod | `aits.need4deed.org` |
| pre | AITS VPS (`n4d-pre` namespace) | StatefulSet pod | `pre.app.need4deed.org`, `pre.need4deed.org` |
| prod | Infomaniak VPS (`n4d-prod` namespace) | Infomaniak managed PostgreSQL | `app.need4deed.org`, `need4deed.org` |

---

## 2. Order from Infomaniak

1. [ ] **VPS — 1×**
   - 4 vCPU / 16 GB RAM. Ubuntu 24.04 LTS.
   - Prod only (pre and dev run on AITS).
   - Note the static public IPv4 after provisioning — whitelist it in Brevo's sender allowlist.

2. [ ] **Managed PostgreSQL — 1×**
   - Prod database only (pre uses a StatefulSet pod on AITS).
   - Note hostname, port, and credentials after provisioning.

3. [ ] **Object Storage buckets — 3×**
   - `n4d-pre-documents` — private; BE document uploads for pre
   - `n4d-prod-documents` — private; BE document uploads for prod
   - `n4d-cdn` — **public read**; static website images
   - Note the S3-compatible endpoint URL, access key, and secret key for each bucket.

4. [ ] **CDN — 1×**
   - Point at the `n4d-cdn` Object Storage bucket.
   - Note the CDN hostname — this becomes the new `IMAGES_CDN_URL` in `website/src/config/constants.ts`.

---

## 3. Code to write in `../infra`

### 3a. Base layer — FE and website are missing

- [ ] `base/fe/deployment.yaml` — FE Deployment (image `ghcr.io/need4deed-org/fe:develop`; port 3000; envFrom `fe-secret`; readiness/liveness on `/api/health`).
- [ ] `base/fe/service.yaml` — ClusterIP Service on port 3000.
- [ ] `base/fe/kustomization.yaml`
- [ ] Update `base/kustomization.yaml` to include `fe/`.
- [ ] `base/website/deployment.yaml` — nginx Deployment; image `ghcr.io/need4deed-org/website:main`; port 80.
- [ ] `base/website/service.yaml` — ClusterIP on port 80.
- [ ] `base/website/kustomization.yaml`
- [ ] Update `base/kustomization.yaml` to include `website/`.
- [ ] Update `base/be/deployment.yaml` — add missing env vars to `be-secret` reference:
  `SLACK_OPS_WEBHOOK_URL`, `SLACK_COMMENTS_WEBHOOK_URL`, `NOTIFY_EMAIL_DRY_RUN`,
  `NOTIFY_SLACK_DRY_RUN`, `CDN_BASE_URL`, `URL_EMAIL_VERIFICATION`, `URL_PASSWORD_RESET`,
  `GIT_COMMIT_SHA`, `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`.

### 3b. Pre overlay (deploys to AITS alongside dev)

- [ ] `overlays/pre/namespace.yaml` — namespace `n4d-pre`.
- [ ] `overlays/pre/ingress.yaml` — two rules on AITS (Traefik handles both namespaces):
  - `pre.app.need4deed.org` → FE service port 3000 (TLS via `letsencrypt`)
  - `pre.need4deed.org` → website service port 80 (TLS via `letsencrypt`)
- [ ] `overlays/pre/kustomization.yaml` — namespace `n4d-pre`; resources: namespace + `../../base` + ingress; image patches to pin `be` and `fe` to `develop` tag.
- [ ] No changes to `scripts/bootstrap.sh` — AITS is already bootstrapped. Just create the `n4d-pre` namespace and secrets manually:
  ```bash
  kubectl create namespace n4d-pre
  kubectl create secret generic postgres-secret -n n4d-pre ...
  kubectl create secret generic be-secret -n n4d-pre ...
  kubectl create secret generic bootstrap-secret -n n4d-pre ...  # DB_* + NODE_ENV + RUN_MIGRATIONS
  ```

### 3c. Prod overlay (deploys to Infomaniak VPS)

- [ ] `overlays/prod/namespace.yaml` — namespace `n4d-prod`.
- [ ] `overlays/prod/ingress.yaml` — two rules:
  - `app.need4deed.org` → FE service port 3000 (TLS via `letsencrypt`)
  - `need4deed.org` and `www.need4deed.org` → website service port 80 (TLS via `letsencrypt`)
- [ ] `overlays/prod/kustomization.yaml` — namespace `n4d-prod`; image patches to pin to `main` tag or SHA. **Patch out the Postgres StatefulSet** (prod uses managed DB — the base StatefulSet must not deploy to prod).
- [ ] `overlays/prod/no-postgres-patch.yaml` — kustomize patch that removes the postgres StatefulSet and Service from the prod overlay (or move postgres out of base into a separate optional component).

### 3d. Bootstrap script for prod VPS

- [ ] `scripts/bootstrap-prod.sh` — installs k3s + Traefik on the Infomaniak VPS, clones the infra repo, creates `n4d-prod` namespace, prints the full `kubectl create secret` commands for all secrets. Include:
  - All BE env vars (DB pointing at managed Postgres host, object storage vars, Slack webhooks, `NOTIFY_*`, etc.)
  - Reminder to whitelist the VPS IP in Brevo before first email send.

### 3e. CI/CD workflows

- [ ] `.github/workflows/deploy-pre.yml` — `workflow_dispatch` + push to `main`; SSH into **AITS**; `git pull && kubectl apply -k overlays/pre/`.
- [ ] `.github/workflows/deploy-prod.yml` — `workflow_dispatch` only; SSH into **Infomaniak prod VPS**; `git pull && kubectl apply -k overlays/prod/`.
- [ ] Add secrets to the `infra` repo: `AITS_HOST` (already exists), `AITS_SSH_KEY` (already exists), `PROD_HOST`, `PROD_SSH_KEY`.
- [ ] Image update strategy: `imagePullPolicy: Always` with fixed branch tags, roll the pod on deploy. Upgrade later to SHA-pinned tags with automated commits from `be`/`fe`/`website` CI.

### 3f. Secrets management

Today every secret lives in the GitHub org and reaches the cluster as `kubectl create secret --from-literal` inside `deploy.yaml`. One org compromise yields the DB password, the JWT secret, both SMTP passwords, the Brevo key, both Slack webhooks and the GHCR PAT.

**Mechanism: SealedSecrets.** The controller (`cluster/sealed-secrets/`, installed per cluster by the bootstrap script) generates an RSA keypair that never leaves the cluster. `scripts/seal-secret.sh` encrypts a value against that cluster's public cert; the ciphertext is committed under `secrets/<cluster>/<namespace>/<name>.yaml` and only that cluster can open it. Git and CI carry ciphertext only. Full procedures in [`docs/runbooks/sealing-keys.md`](docs/runbooks/sealing-keys.md).

Dev keeps its plaintext dummies. Sealing starts at pre and prod: a blob sealed against AITS cannot be decrypted on a local k3d cluster, and `overlays/dev` has to stay portable across both.

**Cutover, per cluster, in this order.** AITS carries both `n4d-dev` and `n4d-pre` under one key; prod is a second key.

- [ ] Install the controller: `kubectl apply -k cluster/sealed-secrets` (bootstrap does this on a fresh VPS).
- [ ] **Export the sealing key and put it in the team vault.** Not in git, not in the GitHub org. Lose it and every committed blob for that cluster is unrecoverable.
- [ ] Verify the export offline with `kubeseal --recovery-unseal`, before trusting it.
- [ ] Fetch the cluster's cert: `scripts/seal-secret.sh fetch-cert <cluster> --context <ctx>`, commit it.
- [ ] Seal each of the five Secrets (`postgres-secret`, `be-secret`, `fe-secret`, `ghcr-secret`, and the `age` key once backups land) from a plaintext file kept outside the repo. Commit under `secrets/<cluster>/<namespace>/`.
- [ ] Include that directory from the overlay that deploys to the cluster.
- [ ] **Annotate the existing Secret `sealedsecrets.bitnami.com/managed=true` before applying.** The controller refuses to take over a Secret it does not own, and it refuses quietly: `kubectl apply` exits 0, the SealedSecret is created, and the old CI value stays live. Check `.status.conditions`, not the apply output.
- [ ] Only after a verified takeover: delete that `kubectl create secret` block from `.github/workflows/deploy.yaml`.
- [ ] Only after that: delete the GitHub Actions secret from the org. This step is the point of the exercise.

Not covered by this: encryption at rest. On single-node k3s the unsealed Secrets and the private key sit in cleartext in kine on the node disk, so a stolen VPS snapshot still yields everything. Full-disk encryption is the control, and it is a decision to make before prod carries real data.

---

## 4. Website (`../website`) changes

### What Amplify is actually doing

Building `yarn build` on push and serving the `dist/` output as a static site + CDN + HTTPS. The `amplify/auth` and `amplify/data` backend scaffolding is unused boilerplate — nothing in `src/` calls it.

### Add to `../website` repo

- [ ] `Dockerfile` — multi-stage build:
  ```
  FROM node:20-alpine AS builder
  WORKDIR /app
  COPY . .
  RUN yarn install --frozen-lockfile && yarn build

  FROM nginx:alpine
  COPY --from=builder /app/dist /usr/share/nginx/html
  COPY nginx.conf /etc/nginx/conf.d/default.conf
  ```
- [ ] `nginx.conf` — with `try_files $uri /index.html` for client-side routing, gzip, and cache headers for static assets.
- [ ] `.github/workflows/build.yml` — on push to `main`: build Docker image, push to `ghcr.io/need4deed-org/website:main`.

### Clean up `../website` repo

- [ ] Remove `aws-amplify` from `dependencies`.
- [ ] Remove `@aws-amplify/backend`, `@aws-amplify/backend-cli`, `aws-cdk`, `aws-cdk-lib`, `constructs` from `devDependencies`.
- [ ] Delete `amplify/` directory.
- [ ] Update `CLOUDFRONT_URL` in `src/config/constants.ts` to the Infomaniak CDN hostname (known after step 2).
- [ ] Rename the constant from `CLOUDFRONT_URL` to something provider-neutral (e.g. `IMAGES_CDN_URL`) while touching the file.
- [ ] Update `VITE_API_URL` default in `.env.local.example` to the new BE domain.
- [ ] `src/config/constants.ts` has a local `positives` array — same pattern as the one renamed to `TRUTHY` in `be`; fix for consistency while touching the file.

---

## 5. Data migration

### 5a. Postgres (prod)

- [ ] Take a fresh RDS snapshot from AWS Console as insurance.
- [ ] `pg_dump` from RDS using the EC2 helper instance in `n4d-infra` (already has `postgresql-client-18`):
  ```bash
  pg_dump -h <rds-host> -U <user> -d <db> -Fc -f n4d-prod-$(date +%F).dump
  ```
- [ ] Restore into Infomaniak managed Postgres:
  ```bash
  pg_restore -h <managed-pg-host> -U <user> -d <db> n4d-prod-$(date +%F).dump
  ```
- [ ] Run `yarn migration:run` against the new DB to confirm it is current.

### 5b. Postgres (pre)

- [ ] Pre can start fresh (restore from a prod dump is optional — useful for realistic test data):
  ```bash
  pg_restore -h localhost -p <port-forward> -U <user> -d <db> n4d-prod-$(date +%F).dump
  ```

### 5c. S3 documents

- [ ] Use `rclone` to copy from AWS S3 to Infomaniak Object Storage:
  ```bash
  rclone sync s3:n4d-main-documents-default infomaniak:n4d-prod-documents
  ```
- [ ] Verify document count and spot-check a few files after migration.

### 5d. Website images

- [ ] Sync images from the CloudFront origin S3 bucket to the Infomaniak `n4d-cdn` bucket:
  ```bash
  rclone sync s3:<cloudfront-origin-bucket>/images infomaniak:n4d-cdn
  ```
- [ ] Verify image count and spot-check a few URLs via the Infomaniak CDN hostname.
- [ ] Update `CLOUDFRONT_URL` → `IMAGES_CDN_URL` in `website/src/config/constants.ts` to the Infomaniak CDN URL.

---

## 6. Cutover sequence

1. [ ] Verify AITS has headroom (`kubectl top nodes`, `free -h`).
2. [ ] Create `n4d-pre` namespace and secrets on AITS. Deploy pre overlay. Smoke test `pre.app.need4deed.org`.
3. [ ] Provision Infomaniak prod VPS. Run `bootstrap-prod.sh`. Create `n4d-prod` secrets.
4. [ ] Restore prod DB dump to Infomaniak managed Postgres. Verify migrations run clean.
5. [ ] Sync S3 documents to Infomaniak Object Storage. Verify BE can read/write.
6. [ ] Sync images to `n4d-cdn` bucket. Verify via Infomaniak CDN URL.
7. [ ] Lower DNS TTL in Namecheap to **60s**, at least 24h before cutover:
   - `need4deed.org`, `www.need4deed.org` (website)
   - `app.need4deed.org` (FE/BE)
8. [ ] Deploy prod overlay to the Infomaniak prod VPS.
9. [ ] Smoke test prod against the VPS IP directly (use `/etc/hosts` entries temporarily).
10. [ ] Switch Namecheap A records:
    - `need4deed.org` → Infomaniak prod VPS IP
    - `www.need4deed.org` → Infomaniak prod VPS IP (or CNAME to `need4deed.org`)
    - `app.need4deed.org` → Infomaniak prod VPS IP
11. [ ] Watch logs on both sides. Wait for TTL to expire (~60–300s).
12. [ ] Scale AWS ECS service to 0 desired count (stops task billing, keeps infra intact as fallback).
13. [ ] After 48h with no issues: proceed to AWS teardown.

---

## 7. AWS teardown order

Run in this order — some resources block deletion if dependents still exist.

- [ ] Remove `deletion_protection = true` from `rds.tf` (set to `false`), apply via Terraform.
- [ ] Scale ECS service to 0 desired count, then destroy: `terraform destroy -target aws_ecs_service.be_service`.
- [ ] Destroy ECS task definition and cluster.
- [ ] Destroy EC2 helper (set `enable_db_helper = false`, apply).
- [ ] Destroy ALB, listeners, target groups.
- [ ] Destroy ACM certificate + Route53 validation records (after Namecheap no longer delegates to Route53).
- [ ] Destroy RDS instance (a final snapshot is taken automatically in prod).
- [ ] Empty and destroy S3 documents bucket (versioned objects need explicit deletion before bucket removal).
- [ ] Empty and destroy S3 images bucket (CloudFront origin).
- [ ] Delete CloudFront distribution.
- [ ] Empty and destroy S3 ALB access-logs bucket (prod only).
- [ ] Destroy CloudWatch log groups.
- [ ] Destroy ECR repositories (after `be`/`fe` CI is publishing to ghcr.io).
- [ ] Destroy security groups.
- [ ] Remove `prevent_destroy` from Route53 zone and ACM cert in `route53.tf`, apply, then destroy hosted zones (only after DNS is fully migrated away from Route53).
- [ ] Destroy VPC module, fck-nat instance, Elastic IP (`vpc/` module).
- [ ] Destroy IAM roles and policies.
- [ ] Destroy Secrets Manager entries (`secrets/` module).
- [ ] Delete Amplify app from AWS Console (removes CloudFormation stacks created by Amplify CDK).
- [ ] Delete Terraform state S3 bucket and lock table manually (last — Terraform can't manage its own backend deletion).
- [ ] Cancel or suspend AWS account if no other workloads use it.

---

## 8. Things that do NOT need code changes

- BE API calls from website and FE — just update `VITE_API_URL` env var.
- Brevo sender — add the Infomaniak prod VPS IP to the Brevo allowlist; no code change in `be`.
- `NOTIFY_*` env vars — already wired in `be`; include them in the k8s secret.
- Google Analytics — no change.
- Slack webhooks — no change; same webhook URLs, just new server sending them.
