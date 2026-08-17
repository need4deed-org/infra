# Cutover readiness - evidence, 17 Aug 2026

Every step of tomorrow's sequence, against what has already been executed.
"Executed" means run for real against this VPS and/or live AWS, output
verified, this week.

| # | Cutover step | Status | Evidence |
|---|---|---|---|
| 1 | Scale AWS be to 0 (stop writes) | permission-proven | no-op `update-service` to current count succeeded (17 Aug); same API call as rollback |
| 1b | Pre-cutover RDS snapshot | permission-proven | `pre-cutover-perm-test-20260817` created (17 Aug) |
| 2 | SSM tunnel to RDS | executed | port-forward via `n4d-network-nat`, dump pulled through it (16 Aug) |
| 3 | Stage RDS credentials | executed | task-definition source, `@sh` quoting, `psql` connected (16 Aug) |
| 4 | Final `pg_dump` | executed | 19 MB db -> 963 KB in 10.3s; counts recorded (16 Aug) |
| 5 | Restore into cluster PG 17 | executed twice | 1.0s, 1267 files; user=72, volunteer+opportunity counts matched source both runs (16 Aug) |
| 5b | Per-database pgBackRest grants | executed | `pgbackrest check` green after grant sequence (15-16 Aug) |
| 6 | Asset delta sync | executed in full | 111 objects/22 MiB synced, `rclone check` clean, object served via Traefik->cdn-proxy: 200 (16 Aug) |
| 7 | be scale-up against restored data | dress-rehearsed | init 15s: genesis backfill, migrations, every seeder "Skipping...", user count unchanged at 72, be Running 1/1 (16 Aug) |
| 8 | Full interactive stack | executed | 17 Aug staging session (`staging.need4deed.org`): browser -> LE TLS -> Traefik -> fe -> `/api` proxy -> be (CORS validated the prod origin list by rejecting staging) -> volunteer form INSERT landed with correct sequence state |
| 9 | DNS flip (`app`) | analog executed | TTL edits on the same records propagated to both authoritative NS in under a minute (16 Aug); `cdn` record already live with issued cert (17 Aug); flip is one panel row with rollback value recorded |
| 10 | Let's Encrypt issuance | executed | staging + cdn certificates issued by the live resolver (17 Aug); `app` may lag up to ~1h post-flip due to accumulated failed-authorization rate limits - documented, self-healing |
| 11 | Post-cutover backup | executed routinely | full 2m41s + incr 8.7s through the CronJob path; nightly armed 02:00 UTC |

Failures already found and fixed by rehearsal (the system works):
truncated bootstrap digest, sed-corrupted DB_PASSWORD, missing scratch
NetworkPolicy, cdn-proxy placeholder project id, private cdn container,
stale bootstrap image missing two upstream fixes.

## Rollback

Trigger: anything unresolvable during the window or soak.

1. Namecheap `app`: back to `CNAME prod-need4deed-lb-2117978489.eu-central-1.elb.amazonaws.com` (TTL 1 min, propagation ~1 min); delete `cdn`.
2. `aws ecs update-service --cluster prod-need4deed-cluster --service prod-need4deed-n4d-service --desired-count 1` - permission proven by tonight's no-op.
3. RDS was never written to and never stopped; the pre-flip snapshot exists as a second anchor.

Cost of rollback: writes made on the VPS after the flip are lost. Decide
early. The rollback path needs nothing that was not already proven tonight:
one DNS edit + one API call already exercised.

## Honestly untested until the day

- Logged-in flows (login, matching) - first smoke after the flip, with an
  existing prod account
- Real email delivery (the 17 Aug staging session ran with notification
  dry-run flags on, deliberately)
