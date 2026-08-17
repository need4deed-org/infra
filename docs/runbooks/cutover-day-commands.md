# Cutover day: paste-ready sequence

Prereqs on the VPS: `~/.aws` configured, session-manager-plugin, postgresql-client-17, rclone remotes, `/mnt/data/dumps`

## 0. Preflight (T-24h and again at window open)

- [ ] Latest backup recent, WAL archiving current:

  ```
  pgb info
  ```

- [ ] `fe`, `cdn-proxy`, `postgres-0` all Running; no be pod (replicas 0):

  ```
  k get pods
  ```

- [ ] Empty diff (exit 0, no output): the cluster matches the repo exactly. Any diff means an unapplied or out-of-band change - resolve it before proceeding:

  ```
  kk diff -k /opt/infra/overlays/prod
  ```

- [ ] Freeze: no deploys either side from here.

## 1. Stop writes: scale AWS be to zero

- [ ] Scale to zero:

  ```
  aws ecs update-service --cluster prod-need4deed-cluster --service prod-need4deed-n4d-service --desired-count 0
  ```

- [ ] Wait until it shows `0 0` (repeat):

  ```
  aws ecs describe-services --cluster prod-need4deed-cluster --services prod-need4deed-n4d-service --query 'services[0].[desiredCount,runningCount]' --output text
  ```

  The site is now DOWN for users. Window open - move briskly, don't rush.
- [ ] Snapshot the quiesced database (extra rollback anchor; no need to wait for it to finish - continue to step 2):

  ```
  aws rds create-db-snapshot --db-instance-identifier prod-need4deed-db --db-snapshot-identifier pre-cutover-$(date +%Y%m%d)
  ```

## 2. Tunnel to RDS (own terminal, stays open)

- [ ] Open the port-forward and leave it running:

  ```
  aws ssm start-session --target i-088beb573d9592006 --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{"host":["prod-need4deed-db.c94wuiawuj5i.eu-central-1.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5433"]}'
  ```

## 3. Stage RDS credentials (second terminal from here on)

- [ ] Stage from the task definition:

  ```
  aws ecs describe-task-definition --task-definition prod-need4deed-n4d-task-definition:37 --query 'taskDefinition.containerDefinitions[?name==`prod-need4deed-be-container`]|[0].environment' --output json | jq -r '[.[] | {(.name): .value}] | add | "export PGUSER=\(.DB_USER|@sh)\nexport PGPASSWORD=\(.DB_PASSWORD|@sh)\nexport PGDATABASE=\(.DB_NAME|@sh)\nexport PGSSLMODE=require"' > ~/secrets-staging/rds.env
  ```

- [ ] Permissions:

  ```
  chmod 600 ~/secrets-staging/rds.env
  ```

- [ ] Parses cleanly (no output):

  ```
  bash -n ~/secrets-staging/rds.env
  ```

- [ ] Load:

  ```
  source ~/secrets-staging/rds.env
  ```

## 4. Final dump

- [ ] Dump (rehearsed: ~10s):

  ```
  time pg_dump -h localhost -p 5433 -Fc -f /mnt/data/dumps/n4d-cutover-$(date +%Y%m%d-%H%M).dump
  ```

- [ ] Note row counts for verification:

  ```
  psql -h localhost -p 5433 -tc 'select count(*) from public.user'
  ```

  ```
  psql -h localhost -p 5433 -tc 'select count(*) from public.volunteer'
  ```

## 5. Restore into the prod cluster

- [ ] Drop the pre-created n4d database so the restore lands clean:

  ```
  kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -c "DROP DATABASE IF EXISTS n4d"'
  ```

- [ ] Recreate:

  ```
  kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -c "CREATE DATABASE n4d OWNER n4d_app"'
  ```

- [ ] Re-grant the pgBackRest functions (per-database; they die with the drop):

  ```
  kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d n4d -c "GRANT EXECUTE ON FUNCTION pg_backup_start, pg_backup_stop, pg_switch_wal, pg_create_restore_point TO pgbackrest"'
  ```

- [ ] Restore (rehearsed: ~1s; use the file from step 4):

  ```
  time kk -n n4d-prod exec -i postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U postgres -d n4d --no-owner --role=n4d_app' < /mnt/data/dumps/n4d-cutover-<TAB-COMPLETE>.dump
  ```

- [ ] Counts match step 4:

  ```
  kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d n4d -tc "select count(*) from public.user"'
  ```

  ```
  kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d n4d -tc "select count(*) from public.volunteer"'
  ```

## 6. Final asset delta sync

- [ ] Sync:

  ```
  rclone sync aws:need4deed-images infomaniak:n4d-cdn -v
  ```

- [ ] Verify:

  ```
  rclone check aws:need4deed-images infomaniak:n4d-cdn --one-way
  ```

## 7. be up

- [ ] Edit `/opt/infra/overlays/prod/kustomization.yaml`: `replicas` for `be`, `count: 0` → `count: 1`.
- [ ] Commit and push:

  ```
  git -C /opt/infra add overlays/prod/kustomization.yaml
  ```

  ```
  git -C /opt/infra commit -m "Cutover: be up"
  ```

  ```
  git -C /opt/infra push
  ```

- [ ] Apply:

  ```
  kk apply -k /opt/infra/overlays/prod
  ```

- [ ] Watch it come up:

  ```
  k get pods -w
  ```

- [ ] Guard against leftover staging overrides (17 Aug session used `kubectl set env`; it survives `apply -k`). Must print only `DB_SSL_CA_PATH`:

  ```
  k get deploy be -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}'
  ```

  If anything NOTIFY/CORS shows up: `k set env deployment/be NOTIFY_EMAIL_DRY_RUN- NOTIFY_SLACK_DRY_RUN- CORS_ORIGINS-`
- [ ] Bootstrap log: expect exactly ONE migration to apply (add-api-key, be#876 - the RDS data predates it); "0 pending" or ">1 pending" are both surprises worth a pause. Every seeder line "Skipping seeding ...":

  ```
  k logs -l app=be -c bootstrap --tail=15
  ```

- [ ] User count from step 5 unchanged:

  ```
  kk -n n4d-prod exec postgres-0 -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d n4d -tc "select count(*) from public.user"'
  ```

## 8. Pre-DNS smoke through the ingress

- [ ] fe answers (expect 307/200):

  ```
  curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: app.need4deed.org' https://localhost/
  ```

- [ ] API through the fe proxy - any HTTP status from be (even 404) proves fe→be→db; a 502 means be is not answering: stop and diagnose before touching DNS:

  ```
  curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: app.need4deed.org' https://localhost/api/
  ```

## 9. DNS flip (Namecheap)

- [ ] `app`: delete the CNAME to the ALB; add `A app -> 179.237.108.234`, TTL 1 min
- [ ] `cdn` already exists and its certificate already issued (17 Aug) - nothing to do
- [ ] apex, `www`, MX, aits, dev: NOT touched

## 10. Certificates and real-URL smoke

The mechanism is proven (staging + cdn certs issued 17 Aug). Expectation for `app`: Traefik has been burning failed authorizations against it for days (DNS still pointed at the ALB), and Let's Encrypt rate-limits failed authorizations per hostname per hour - so the app certificate may take up to ~an hour after the flip, not two minutes. It self-heals; do not restart or reconfigure anything.

- [ ] Watch issuance:

  ```
  kk -n kube-system logs deploy/traefik --tail=50 | grep -i acme
  ```

- [ ] From any machine:

  ```
  curl -s -o /dev/null -w '%{http_code}\n' https://app.need4deed.org/
  ```

  ```
  curl -s -o /dev/null -w '%{http_code}\n' https://cdn.need4deed.org/data/de/testimonials.json
  ```

- [ ] Real smoke, in a browser: log in, run a matching flow, trigger an email and confirm it arrives (Brevo/SMTP path).

## 11. Close the window

- [ ] First backup of the migrated data:

  ```
  pgb backup --type=incr
  ```

- [ ] Confirm it in the repo:

  ```
  pgb info
  ```

Window closed. Soak begins: daily `pgb info`, disk, pod restarts, cert state, error logs.

## 12. Rollback (any time during soak)

- [ ] Namecheap: `app` back to `CNAME prod-need4deed-lb-2117978489.eu-central-1.elb.amazonaws.com`; remove `cdn`
- [ ] Scale AWS back up:

  ```
  aws ecs update-service --cluster prod-need4deed-cluster --service prod-need4deed-n4d-service --desired-count 1
  ```

Writes made on the VPS after the flip do NOT flow back to RDS - rollback loses them. Roll back early or not at all.

## Post-soak (before or at teardown)

- [ ] Revoke the tunnel SG rule:

  ```
  aws ec2 revoke-security-group-ingress --group-id sg-09bfae366f290f9f5 --protocol tcp --port 5432 --source-group sg-0b4d2c98a65fdc00f
  ```

- [ ] `shred -u ~/secrets-staging/rds.env`
- [ ] AITS jump host + close port 22 (see provisioning report)
