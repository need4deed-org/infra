#!/usr/bin/env bash
# Section 4 first-boot checks for the prod database
# (provisioning-runbook-sealedsecrets-pg.md). Run as a sudoer on the VPS:
#   bash scripts/prod-checks.sh
set -euo pipefail

NS=n4d-prod
KUBECTL="kubectl"
[ -r "${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}" ] || KUBECTL="sudo kubectl"
PG_IMAGE=$($KUBECTL -n "$NS" get statefulset postgres \
  -o jsonpath='{.spec.template.spec.containers[0].image}')

echo "=== 1/3  Roles exist (postgres, n4d_app, pgbackrest) ==="
# exec enters as root, so peer auth is unavailable; scram with the
# password from the container's own environment, over the socket.
$KUBECTL -n "$NS" exec postgres-0 -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -c "\du"'

echo "=== 2/3  Plaintext connection is refused ==="
# Client pod labelled app: pg-backup (the netpol admits only be and
# pg-backup to 5432), postgres image for psql, pinned CA mounted.
$KUBECTL apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pgtest
  namespace: $NS
  labels:
    app: pg-backup
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: $PG_IMAGE
      command: ["sleep", "3600"]
      env:
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: pgbackrest-secret
              key: PG_BACKUP_PASSWORD
      volumeMounts:
        - name: ca
          mountPath: /ca
          readOnly: true
  volumes:
    - name: ca
      secret:
        secretName: postgres-ca
EOF
$KUBECTL -n "$NS" wait --for=condition=Ready pod/pgtest --timeout=120s >/dev/null

if $KUBECTL -n "$NS" exec pgtest -- \
    psql "host=postgres user=pgbackrest dbname=postgres sslmode=disable" \
    -c 'select 1' 2>/tmp/pgtest-err; then
  echo "FAIL: plaintext connection was ACCEPTED. hostssl is not enforcing."
  exit 1
else
  grep -q 'SSL off\|no pg_hba' /tmp/pgtest-err \
    && echo "OK: refused ($(tail -1 /tmp/pgtest-err))" \
    || { echo "Refused, but not by pg_hba - inspect:"; cat /tmp/pgtest-err; exit 1; }
fi

echo "=== 3/3  TLS with the pinned CA connects ==="
$KUBECTL -n "$NS" exec pgtest -- \
  psql "host=postgres user=pgbackrest dbname=postgres sslmode=verify-full sslrootcert=/ca/ca.crt" \
  -tc 'select version()'

echo ""
echo "All three passed. Clean up the test pod when done with it:"
echo "  $KUBECTL -n $NS delete pod pgtest"
