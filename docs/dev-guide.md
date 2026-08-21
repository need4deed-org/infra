# Developer guide: the production VPS

How to work on the n4d production platform: getting onto the machine,
talking to the database, and deploying new versions of the fe and be.

Production runs on a single Infomaniak VPS as a k3s cluster, namespace
`n4d-prod`. The app is at `https://app.need4deed.org`, assets at
`https://cdn.need4deed.org`. Deploys are declarative: the cluster runs
what `overlays/prod` in this repo describes, nothing else.

## Getting on the machine

```
ssh ubuntu@179.237.108.234
```

Key-only. Your public key must be a line in `~/.ssh/authorized_keys` on the
VPS (one line per person; ask an existing operator to add yours). Password
login is off.

kubectl needs sudo: the kubeconfig (`/etc/rancher/k3s/k3s.yaml`) is
root-only. The default context namespace is `n4d-prod`. The operator
account has these helpers in `~/.bashrc`:

- `k` = `sudo kubectl -n n4d-prod` - day-to-day: `k get pods`, `k logs -l app=be`
- `kk` = `sudo kubectl` - cluster-wide: `kk get ns`, `kk -n kube-system logs deploy/traefik`
- `pgb <args>` - pgBackRest inside the postgres pod, stanza and password preset: `pgb info`, `pgb check`
- `pgsql <args>` - psql inside the postgres pod as the `postgres` superuser: `pgsql -d n4d`, `pgsql -c '\du'`

## The database

PostgreSQL 17 runs in the cluster as `postgres-0`, storage on the VPS data
disk. TLS is enforced (`hostssl`): plaintext connections are refused, and
clients verify the server against a pinned CA, not the public roots.

Interactive access:

```
pgsql -d n4d
```

Roles: `postgres` (superuser, operations only), `n4d_app` (owns the `n4d`
database; what the be connects as), `pgbackrest` (backups). The be reaches
the database only in-cluster; there is no external database endpoint.

Backups: pgBackRest, nightly at 02:00 UTC via the `pg-backup` CronJob, to
an encrypted repo in Infomaniak Object Storage. Check state with
`pgb info`. A failed backup posts to the ops Slack channel. Restore
procedure and rehearsal timings: `docs/runbooks/db-restore.md` - read it
before you need it.

Do not hand-edit data in `n4d` without a reason that survives being asked
about it later; there is no staging buffer in front of this database.

## Deploying a new fe or be version

The moving parts: images are built by GitHub Actions and published to
GHCR; the cluster runs whatever `overlays/prod/kustomization.yaml` pins.
Every image is pinned by digest, so merging and building alone changes
nothing in production - a deploy is always an edit to the pin, and pod
restarts are no-ops. "What is production running" is answered by that
one file.

### be

Merging to `develop` in the `be` repo publishes a new `be:develop` image.
To deploy it:

1. Get the digest of the build you want:
   `docker buildx imagetools inspect ghcr.io/need4deed-org/be:develop`
   (or from the workflow run's logs)
2. Update the `be` digest in `overlays/prod/kustomization.yaml`
3. Apply (below)

Two things happen on be startup that you should know about:

1. The bootstrap init container and the be itself run pending database
   migrations (with `NODE_ENV=production` this is unconditional). A bump
   to an image containing a migration migrates the production schema the
   moment it starts.
2. Seeding runs but skips every table that already has rows. On the
   production database this is a no-op; it only matters on empty databases.

If your be change adds a migration, also rebuild the bootstrap image
(`build-bootstrap` workflow in the be repo) and update its digest pin in
the same commit, so the two images agree on the migration set.

Rollback is `git revert` of the pin commit, then apply. An image revert
does not revert a migration the image already ran: rolling back past a
schema change needs that change to be backward-compatible, or undone by
hand.

### fe

The fe repo's `build-fe.yaml` workflow builds and publishes the image.
The API URL and CDN asset hosts are baked in at build time (Next.js
`NEXT_PUBLIC_*`/build args), so a change to those needs a rebuild, not an
env change. After the workflow runs:

1. Get the new digest: the workflow logs print it, or
   `docker buildx imagetools inspect ghcr.io/<owner>/fe:develop`
2. Update the `fe` digest in `overlays/prod/kustomization.yaml`
3. Deploy (below)

### Applying changes to the cluster

All manifest changes, image pins included, deploy the same way:

```
git -C /opt/infra pull
```

```
kk diff -k /opt/infra/overlays/prod
```

Read the diff. It should contain exactly what you expect and nothing else.
Then:

```
kk apply -k /opt/infra/overlays/prod
```

```
k get pods -w
```

An empty diff after `apply` is the definition of "deployed".

## Secrets

Secrets are SealedSecrets: encrypted blobs in `secrets/prod/n4d-prod/`,
decryptable only by the cluster. To add or change one, follow
`secrets/README.md` and `docs/runbooks/sealing-keys.md` - the short
version is `scripts/seal-secret.sh` with a plaintext env file that lives
outside the repo, then commit the sealed blob and add it to
`secrets/prod/n4d-prod/kustomization.yaml`. The prod overlay includes
that directory, so the blob deploys through the normal loop above
(`kk diff -k /opt/infra/overlays/prod`, then apply) - a committed
rotation shows up in the diff like any other change.

The success signal is `Synced=True` on the SealedSecret (a bad blob fails
silently otherwise):

```
k get sealedsecret <name> -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}'
```

Pods only read secrets at startup: restart the consuming deployment after
a change.

## When something is wrong

- `k get pods` then `k logs <pod>` (`-c bootstrap` for the be init
  container). `k describe pod <pod>` for image pull and scheduling issues.
- Certificates: `kk -n kube-system logs deploy/traefik | grep -i acme`.
  Traefik can go dormant on ACME retries after repeated failures; deleting
  and re-applying the relevant Ingress forces a fresh attempt.
- Backups: `pgb info` and `pgb check`.
- Disk: `df -h /mnt/data` - everything that grows lives there.
