# Restoring the Postgres database

Applies to the interim self-hosted Postgres (`components/postgres` plus
`components/postgres-prod`), until the Infomaniak PostgreSQL DBaaS replaces it.

## Before you start

You need four things. Without the first, nothing else matters.

| What | Where it lives |
| --- | --- |
| `PGBACKREST_REPO1_CIPHER_PASS` | `pgbackrest-secret`, sealed in the repo and in the password manager |
| `PGBACKREST_REPO1_S3_KEY` / `_KEY_SECRET` | `pgbackrest-secret`, Infomaniak Object Storage credentials |
| `postgres-tls` / `postgres-ca` | sealed secrets, regenerated with `scripts/gen-postgres-tls.sh <namespace>` |
| The sealing key | the SealedSecrets controller's key backup |

**The repository is encrypted client side.** A rebuilt cluster with a fresh
sealing key cannot read a single backup without the cipher passphrase. Restore
the passphrase before anything else; there is no recovery path from losing it.

Every command below runs in a pod from `ghcr.io/need4deed-org/postgres`, which
carries pgBackRest. `kubectl exec` into the postgres pod, or start a throwaway
pod with `pgbackrest-secret` and the `pgbackrest-config` ConfigMap mounted.

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

## Restore into a scratch namespace

The safe default. It leaves production running while you check the data.

1. Create the namespace and copy `postgres-secret`, `pgbackrest-secret`,
   `postgres-tls`, `postgres-ca`, `pgbackrest-config` and `postgres-pg-hba`
   into it.
2. Run the restore into an empty PGDATA:

```
mkdir -p /var/lib/postgresql/data/pgdata
chmod 0700 /var/lib/postgresql/data/pgdata
pgbackrest --stanza=n4d restore
```

3. Start postgres with **`-c archive_mode=off`**. A restored instance promotes
   onto a new timeline; with archiving on it pushes that timeline into the same
   repository and mixes two histories in one stanza.

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

Only after a scratch restore has confirmed the data. Scale the StatefulSet to 0
first, then:

```
pgbackrest --stanza=n4d restore --delta
```

`--delta` compares checksums and rewrites only what differs, which is far faster
than an empty-directory restore on a large database. It refuses to run if the
directory is not a recognisable PGDATA.

## Bootstrapping a brand-new cluster

`stanza-create` comes before everything. Until it runs, `archive_command` fails
on every segment with error 103 and postgres holds WAL on local disk:

```
pgbackrest --stanza=n4d stanza-create
pgbackrest --stanza=n4d check
```

`stanza-create` is idempotent and exits 0 against an existing valid stanza, so
the nightly CronJob runs it every night on purpose. Once the stanza exists, the
backlog of held segments drains on its own.

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

## Measured numbers

From the k3d validation run on 2026-08-01 against MinIO, on a 32.9MB database
with 1511 files:

| | |
| --- | --- |
| Full backup | 7 to 8s, 3.9MB in the repository after zstd and encryption |
| Whole CronJob (stanza-create, check, backup, expire) | 16s |
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
`images/postgres`. A CVE fix in 17.x no longer arrives by re-pulling a tag:
re-run `build-postgres-image.yaml`, then update the digest in
`components/postgres/statefulset.yaml` and `backup-cronjob.yaml`. This ends when
the DBaaS migration deletes the component.

**The `n4d` to `n4d_app` switch.** The BE connects as the superuser created by
`POSTGRES_USER`. `n4d_app` exists and is not a superuser, but every object is
owned by `n4d`, so switching needs `REASSIGN OWNED BY n4d TO n4d_app` plus a
`DB_USER` change in `be-secret` and `bootstrap-secret`, applied together. It is a
coordinated cutover, not a config edit.
