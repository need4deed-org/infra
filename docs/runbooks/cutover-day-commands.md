# Cutover day: paste-ready sequence

Every step: one command, check the output, then move on. Rollback at any
point before step 9 is simply "do nothing" (AWS is still serving). After
step 9, rollback = step 12.

Prereqs on the VPS: `~/.aws` configured, session-manager-plugin,
postgresql-client-17, rclone remotes, `/mnt/data/dumps` - all in place and
proven 2026-08-16.

## 0. Preflight (T-24h and again at window open)

```
pgb info
```
Latest backup recent, WAL archiving current.

```
k get pods
```
`fe`, `cdn-proxy`, `postgres-0` all Running; no be pod (replicas 0).

```
kk diff -k /opt/infra/overlays/prod
```
Must be empty (exit 0, no output): the cluster matches the repo exactly
before the window opens. Any diff means an unapplied or out-of-band change -
resolve it before proceeding.

Freeze: no deploys either side from here.

## 1. Stop writes: scale AWS be to zero

```
aws ecs update-service --cluster prod-need4deed-cluster --service prod-need4deed-n4d-service --desired-count 0
```

Wait until running count is 0 (repeat until it shows `0 0`):

```
aws ecs describe-services --cluster prod-need4deed-cluster --services prod-need4deed-n4d-service --query 'services[0].[desiredCount,runningCount]' --output text
```

The site is now DOWN for users. Window open - move briskly, don't rush.

Snapshot the quiesced database (extra rollback anchor; permission proven
16 Aug):

```
aws rds create-db-snapshot --db-instance-identifier prod-need4deed-db --db-snapshot-identifier pre-cutover-$(date +%Y%m%d)
```

No need to wait for it to finish - it snapshots the stopped-writes state
regardless; continue to step 2.

## 2. Tunnel to RDS (own terminal, stays open)

```
aws ssm start-session --target i-088beb573d9592006 --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{"host":["prod-need4deed-db.c94wuiawuj5i.eu-central-1.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5433"]}'
```

## 3. Stage RDS credentials (second terminal from here on)

```
aws ecs describe-task-definition --task-definition prod-need4deed-n4d-task-definition:37 --query 'taskDefinition.containerDefinitions[?name==`prod-need4deed-be-container`]|[0].environment' --output json | jq -r '[.[] | {(.name): .value}] | add | "export PGUSER=\(.DB_USER|@sh)\nexport PGPASSWORD=\(.DB_PASSWORD|@sh)\nexport PGDATABASE=\(.DB_NAME|@sh)\nexport PGSSLMODE=require"' > ~/secrets-staging/rds.env
```

```
chmod 600 ~/secrets-staging/rds.env
```

```
bash -n ~/secrets-staging/rds.env
```

```
source ~/secrets-staging/rds.env
```

## 4. Final dump

```
time pg_dump -h localhost -p 5433 -Fc -f /mnt/data/dumps/n4d-cutover-$(date +%Y%m%d-%H%M).dump
```

Rehearsed: ~10s. Note row counts for verification:

```
psql -h localhost -p 5433 -tc 'select count(*) from public.user'
```

```
psql -h localhost -p 5433 -tc 'select count(*) from public.volunteer'
```

## 5. Restore into the prod cluster

Drop and recreate the (empty, pre-created) n4d database so the restore
lands clean:

```
kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -c "DROP DATABASE IF EXISTS n4d"'
```

```
kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -c "CREATE DATABASE n4d OWNER n4d_app"'
```

Re-grant the pgBackRest functions (they are per-database and die with the drop):

```
kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d n4d -c "GRANT EXECUTE ON FUNCTION pg_backup_start, pg_backup_stop, pg_switch_wal, pg_create_restore_point TO pgbackrest"'
```

Restore (rehearsed: ~1s; use the file from step 4):

```
time kk -n n4d-prod exec -i postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U postgres -d n4d --no-owner --role=n4d_app' < /mnt/data/dumps/n4d-cutover-<TAB-COMPLETE>.dump
```

Verify counts against step 4:

```
kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d n4d -tc "select count(*) from public.user"'
```

```
kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d n4d -tc "select count(*) from public.volunteer"'
```

## 6. Final asset delta sync

```
rclone sync aws:need4deed-images infomaniak:n4d-cdn -v
```

```
rclone check aws:need4deed-images infomaniak:n4d-cdn --one-way
```

## 7. be up

Edit `/opt/infra/overlays/prod/kustomization.yaml`: `replicas` for `be`,
`count: 0` → `count: 1`. Then:

```
git -C /opt/infra add overlays/prod/kustomization.yaml
```

```
git -C /opt/infra commit -m "Cutover: be up"
```

```
git -C /opt/infra push
```

```
kk apply -k /opt/infra/overlays/prod
```

```
k get pods -w
```

Guard against leftover staging overrides (17 Aug session used `kubectl set
env` for dry-run/CORS flags; they survive `apply -k`). This must print only
`DB_SSL_CA_PATH`:

```
k get deploy be -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}'
```

If anything NOTIFY/CORS shows up: `k set env deployment/be NOTIFY_EMAIL_DRY_RUN- NOTIFY_SLACK_DRY_RUN- CORS_ORIGINS-`

Rehearsed arc: init ~15s, then Running 1/1. Expect exactly ONE migration to
apply (add-api-key, be#876, merged upstream 16 Aug evening - the RDS data
predates it); "0 pending" or ">1 pending" would both be surprises worth a
pause. Then confirm seeding skipped:

```
k logs -l app=be -c bootstrap --tail=15
```

Every line "Skipping seeding ..."; user count from step 5 unchanged:

```
kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d n4d -tc "select count(*) from public.user"'
```

## 8. Pre-DNS smoke through the ingress

```
curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: app.need4deed.org' https://localhost/
```

Expect 307/200 (fe). API through the fe proxy:

```
curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: app.need4deed.org' https://localhost/api/
```

Any HTTP status from be (even 404) proves fe→be→db; a 502 means be is not
answering - stop and diagnose before touching DNS.

## 9. DNS flip (Namecheap)

- `app`: delete the CNAME to the ALB; add `A app -> 179.237.108.234`, TTL 1 min
- `cdn` already exists and its certificate already issued (17 Aug) - nothing to do
- apex, `www`, MX, aits, dev: NOT touched

## 10. Certificates and real-URL smoke

The mechanism is proven (staging + cdn certs issued 17 Aug). Expectation
for `app`: Traefik has been burning failed authorizations against it for
days (DNS still pointed at the ALB), and Let's Encrypt rate-limits failed
authorizations per hostname per hour - so the app certificate may take up
to ~an hour after the flip, not two minutes. It self-heals; do not
restart or reconfigure anything, just watch:

```
kk -n kube-system logs deploy/traefik --tail=50 | grep -i acme
```

Then from any machine:

```
curl -s -o /dev/null -w '%{http_code}\n' https://app.need4deed.org/
```

```
curl -s -o /dev/null -w '%{http_code}\n' https://cdn.need4deed.org/data/de/testimonials.json
```

Real smoke, in a browser: log in, run a matching flow, trigger an email and
confirm it arrives (Brevo/SMTP path).

## 11. Close the window

```
pgb backup --type=incr
```

```
pgb info
```

First backup of the migrated data in the repo. Window closed. Soak begins:
daily `pgb info`, disk, pod restarts, cert state, error logs.

## 12. Rollback (any time during soak)

- Namecheap: `app` back to `CNAME prod-need4deed-lb-2117978489.eu-central-1.elb.amazonaws.com`; remove `cdn`
- ```
  aws ecs update-service --cluster prod-need4deed-cluster --service prod-need4deed-n4d-service --desired-count 1
  ```
- Writes made on the VPS after the flip do NOT flow back to RDS - rollback
  loses them. Roll back early or not at all.

## Post-soak (before or at teardown)

- Revoke the tunnel SG rule:
  ```
  aws ec2 revoke-security-group-ingress --group-id sg-09bfae366f290f9f5 --protocol tcp --port 5432 --source-group sg-0b4d2c98a65fdc00f
  ```
- `shred -u ~/secrets-staging/rds.env`
- AITS jump host + close port 22 (see provisioning report)
