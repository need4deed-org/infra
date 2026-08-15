# Restoring the Postgres database

Applies to the interim self-hosted Postgres (`components/postgres` plus
`components/postgres-prod`), until the Infomaniak PostgreSQL DBaaS replaces it.

## Before you start

Without the first row, nothing else matters.

| What | Where it lives |
| --- | --- |
| `PGBACKREST_REPO1_CIPHER_PASS` | `pgbackrest-secret`, sealed in the repo and in the password manager |
| `PGBACKREST_REPO1_S3_KEY` / `_KEY_SECRET` | `pgbackrest-secret`, Infomaniak Object Storage credentials |
| `PG_BACKUP_PASSWORD` | `pgbackrest-secret`, the `pgbackrest` role's password |
| `N4D_APP_PASSWORD` | `postgres-secret`, the `n4d_app` role's password |
| `SLACK_OPS_WEBHOOK_URL`, `DEADMAN_URL` | `pg-backup-alerts`, optional; without it a failed backup is reported only into the Job log |
| `postgres-tls` / `postgres-ca` | sealed secrets, regenerated with `scripts/gen-postgres-tls.sh <namespace>` |
| The sealing key | the SealedSecrets controller's key backup |

**The repository is encrypted client side.** A rebuilt cluster with a fresh
sealing key cannot read a single backup without the cipher passphrase. Restore
the passphrase before anything else; there is no recovery path from losing it.

The two role passwords are read once, at `initdb`. The StatefulSet names them as
required keys so a missing one stops the pod before it starts, because a first
boot that gets past `initdb` and then fails the role script never runs the init
directory again: the cluster comes up Ready and permanently without `n4d_app`
and `pgbackrest`, and the only symptom is the nightly backup failing to
authenticate. Recovery from that is recreating the volume.

Every command below runs in a pod from `ghcr.io/need4deed-org/postgres`, which
carries pgBackRest. `kubectl exec` into the postgres pod, or start a throwaway
pod with `pgbackrest-secret` and the `pgbackrest-config` ConfigMap mounted.
Commands that reach the database (`stanza-create`, `check`, `backup`)
authenticate as the `pgbackrest` role, and inside the postgres pod that goes
over the local socket, which `pg_hba.conf` gates with scram: prefix them with
`PGPASSWORD="$PG_BACKUP_PASSWORD"`. `info` and `repo-ls` only read the
repository. The CronJob needs none of this; it sets `PGHOST` and `PGPASSWORD`
itself, so `kubectl create job --from=cronjob/pg-backup <name>` is the shortest
way to run a checked backup by hand.

## Applying this to an existing volume

`PGDATA` is a subdirectory of the volume, `/var/lib/postgresql/data/pgdata`. A
cluster created before this component lives at the volume root, and postgres
does not migrate it: the entrypoint finds no `PG_VERSION` under `pgdata/`, runs
`initdb`, and comes up empty with the old files still on the volume, invisible
and still occupying it. `--data-checksums` is the same kind of one-shot
decision. So every existing environment, AITS dev included, needs its volume
recreated deliberately, after dumping anything worth keeping:

```
kubectl -n <ns> scale statefulset postgres --replicas=0
kubectl -n <ns> delete pvc data-postgres-0
kubectl -n <ns> scale statefulset postgres --replicas=1
```

The `assert-pgdata-layout` init container is there so this cannot happen by
accident: it fails while the old cluster is still at the volume root, which
holds the pod in `Init:Error` with that message in its log instead of letting
postgres come up as an empty database. Deleting the volume clears it. To reach
the old files after it has tripped, disable it for one boot and restore it by
re-applying the overlay:

```
kubectl -n <ns> patch statefulset postgres -p '{"spec":{"template":{"spec":{"initContainers":[{"name":"assert-pgdata-layout","command":["true"]}]}}}}'
```

## See what exists

```
pgbackrest --stanza=n4d info
```

Read three things: `status: ok`, the newest `full backup` timestamp, and
`wal archive min/max`. A gap between the newest backup and the WAL maximum is
how far a point-in-time restore can reach.

`repo-ls` lists raw objects when `info` is not enough:

```
pgbackrest --stanza=n4d repo-ls backup/n4d
pgbackrest --stanza=n4d repo-ls archive/n4d/17-1/0000000100000000
```

## A pod that holds PGDATA with postgres stopped

Every restore needs one. `pgbackrest restore` writes into `PGDATA`, so the
postmaster must not be running, and the volume is `ReadWriteOnce`, so a second
pod cannot take it while the StatefulSet has one. Turn the postgres pod itself
into that pod:

```
kubectl -n <ns> patch statefulset postgres -p '{"spec":{"template":{"spec":{"containers":[{"name":"postgres","command":["sleep","infinity"],"args":null,"startupProbe":null,"livenessProbe":null,"readinessProbe":null}]}}}}'
kubectl -n <ns> rollout status statefulset/postgres
```

`args` and the probes have to go with the command: the args are the postgres
command line and `sleep` would choke on them, and the probes run `pg_isready`
against a postmaster that is not there, so the startup probe would kill the
container five minutes into the restore. The pod keeps every mount and secret
pgBackRest needs. Afterwards:

```
kubectl -n <ns> patch statefulset postgres -p '{"spec":{"template":{"spec":{"containers":[{"name":"postgres","command":null}]}}}}'
kubectl apply -k overlays/<env>/
```

`apply` puts the probes back but would leave the command: `kubectl patch` does
not update the last-applied annotation, so the explicit null is what removes it.

## Restore into a scratch namespace

The safe default. It leaves production running while you check the data.

1. Copy `overlays/<env>` with `namespace:` pointed at the scratch namespace, add
   **`-c archive_mode=off`** to the postgres `args` (the last `-c` wins), and
   apply it. A restored instance promotes onto a new timeline; with archiving on
   it pushes that timeline into the same repository and mixes two histories in
   one stanza.
2. Copy `postgres-secret`, `pgbackrest-secret`, `postgres-tls` and `postgres-ca`
   into the namespace. The ConfigMaps come from the overlay.
3. The new volume comes up as an empty cluster from `initdb`. Stop postgres as
   above and restore over it:

```
pgbackrest --stanza=n4d restore --delta
```

With no `--type`, recovery replays every archived segment and promotes at the
end, so you get the database as of the last archived WAL, not as of the backup.

## Point in time

```
pgbackrest --stanza=n4d restore \
  --type=time --target='2026-08-01 13:54:48+00' --target-action=promote
```

The target format is `YYYY-MM-DD HH:MM:SS` with an optional timezone. pgBackRest
rejects the ISO `T` separator with error 029. Always give an explicit `+00`;
without one it assumes local time.

Confirm the stop point in the server log before trusting the data:

```
LOG: recovery stopping before commit of transaction 1173, time ...
LOG: last completed transaction was at log time ...
```

## Restore in place over the live volume

Only after a scratch restore has confirmed the data. Stop postgres as above,
then:

```
pgbackrest --stanza=n4d restore --delta
```

`--delta` compares checksums and rewrites only what differs, which is far faster
than an empty-directory restore on a large database. It refuses to run if the
directory is not a recognisable PGDATA.

Recovery replays from the repository over the internet, and `pg_isready` reports
"rejecting connections" for the whole of it. Raise
`startupProbe.failureThreshold` past the 30 in the manifest before starting
postgres again on anything much larger than the measured database below, or the
kubelet kills the container mid-replay and it presents as a crash loop.

## Bootstrapping a brand-new cluster

`stanza-create` comes before everything. Until it runs, `archive_command` fails
on every segment with error 103 and postgres holds WAL on local disk:

```
PGPASSWORD="$PG_BACKUP_PASSWORD" pgbackrest --stanza=n4d stanza-create
PGPASSWORD="$PG_BACKUP_PASSWORD" pgbackrest --stanza=n4d check
```

Once the stanza exists, the backlog of held segments drains on its own.

`stanza-create` is idempotent against an existing valid stanza, but the nightly
CronJob does not run it unconditionally: against a repository that has lost its
stanza it would rebuild an empty one, and `check`, `backup` and `info` would all
then pass against that, reporting a healthy backup on the night every recovery
point was lost. The job creates the stanza only when `info` reports none, and
says so on the alert channel when it does.

## When `pgbackrest check` fails

The nightly job runs `check` before the backup precisely so this is loud. Read
the error class first:

- `[103] unable to find a valid repository` with `archive.info ... missing`: the
  stanza does not exist. Run `stanza-create`.
- `[039] SignatureDoesNotMatch` or `AccessDenied`: the Object Storage credentials
  in `pgbackrest-secret` are wrong or revoked.
- `[HostConnectError] timeout connecting to`: the object store is unreachable.
  Check the `postgres-egress` and `pg-backup-egress` NetworkPolicies, then the
  provider. Both policies allow TCP 443 and DNS to kube-system and nothing else,
  so a missing DNS rule looks exactly like a credentials problem.
- `[087] archive_mode must be enabled`: the prod component is not applied, or
  something replaced the postgres `args`.

Until `check` passes, treat the last successful backup in `pgbackrest info` as
the real recovery point, not the schedule.

**Archiving that is failing has a deadline.** Postgres keeps every unarchived
segment in `pg_wal`, and `archive_timeout=300` forces a segment switch every
five minutes even with no writes: about 192MB an hour, 4.6GB a day, against a
20Gi claim that `local-path` cannot expand and a `volumeClaimTemplate` that
cannot be edited. Roughly three days of a broken `archive_command` fills the
volume, and a full volume PANICs postgres and keeps it down. `select * from
pg_stat_archiver` gives `failed_count` and the last successful segment; `du -sh
$PGDATA/pg_wal` gives the headroom. If it does fill, free space by restoring
onto a new volume from the last backup. Deleting unarchived WAL by hand is
accepting the data loss it represents.

## Measured numbers

From the k3d validation run on 2026-08-01 against MinIO, on a 32.9MB database
with 1511 files:

| | |
| --- | --- |
| Full backup | 7 to 8s, 3.9MB in the repository after zstd and encryption |
| Whole CronJob (check, backup, expire) | 16s |
| `pgbackrest restore` | 5.5s |
| Restore to accepting connections (RTO) | 20 to 25s |
| Point-in-time restore to accepting connections | 21s |
| Write to segment in the repository, idle database (RPO) | 103s, bounded by `archive_timeout=300` |

These scale with database size and with the link to Infomaniak. Re-measure after
the first real backup; the RPO bound does not change, because it is a timer.

## Retention

`repo1-retention-full-type=time` with `repo1-retention-full=30` keeps 30 days.
Expire runs automatically after each successful backup and removes the WAL that
belonged to the expired backup along with it. There are no lifecycle rules on
the Infomaniak gateway, so this is the only thing deleting anything.

Verified: after an expire, the expired backup set and its WAL range are gone
from the bucket and the surviving backup still restores completely.

## Two things this database still owes

**Image patch cadence.** The image is pinned by digest and built from
`images/postgres`, whose `FROM` is itself pinned by digest. A CVE fix in 17.x
therefore does not arrive by re-running `build-postgres-image.yaml`: that
rebuilds the same content. Bump the `FROM` digest in `images/postgres/Dockerfile`
(and usually `PGBACKREST_VERSION`, because PGDG carries only current versions
and an old pin eventually stops resolving), then copy the new digest into the
`images:` entry in `components/postgres-prod/kustomization.yaml`. This ends when
the DBaaS migration deletes the component.

**The `n4d` to `n4d_app` switch.** The BE connects as the superuser created by
`POSTGRES_USER`. `n4d_app` exists and is not a superuser, but every object is
owned by `n4d`, so switching needs `REASSIGN OWNED BY n4d TO n4d_app` plus a
`DB_USER` change in `be-secret` and `bootstrap-secret`, applied together. It is a
coordinated cutover, not a config edit.

This is a security prerequisite for prod, not tidiness. `archive_command` runs
inside the postmaster, so the Object Storage credentials and the repository
cipher passphrase are in the postmaster's environment, and a superuser session
reads them with `COPY ... FROM PROGRAM`. Until the BE stops connecting as a
superuser, a SQL injection or a leaked `be-secret` costs the backups as well as
the database: the credential can delete the repository and the passphrase
decrypts it, and the Infomaniak gateway offers no bucket policies, no lifecycle
rules and no object lock to fall back on.
