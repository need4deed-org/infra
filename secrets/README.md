# Sealed secrets

Ciphertext only. Everything here is safe to commit and safe to read.

## Layout

```
secrets/<cluster>/pub-cert.pem          public sealing cert of that cluster
secrets/<cluster>/<namespace>/<name>.yaml
```

The private key never leaves the cluster it was generated on, so a blob is
decryptable by exactly one cluster. Blobs are sealed at strict scope: the
ciphertext is bound to that name in that namespace, and moving the file
somewhere else produces a decryption error, not a secret. The directories are
that binding made visible in review.

Directories appear when there is something to put in them. There are no
placeholder `resources: []` kustomizations here.

## Sealing

Needs `kubeseal` (pinned version and checksum in
[docs/runbooks/sealing-keys.md](../docs/runbooks/sealing-keys.md)).

```bash
scripts/seal-secret.sh fetch-cert aits --context <kubectl-context>
scripts/seal-secret.sh seal aits n4d-pre be-secret --env-file ~/n4d-pre-be.env
```

The plaintext input file must live outside this repo; the script refuses
otherwise. `ghcr-secret` is a `kubernetes.io/dockerconfigjson` and is sealed
with `--dockerconfigjson`, from a file, so the PAT never reaches argv.

After sealing, add the file to that namespace directory's `kustomization.yaml`
and include the directory from the overlay that deploys to that cluster.

## What this is not

Not encryption at rest. The controller writes a plain `Secret`, and on
single-node k3s that Secret and the private key sit unencrypted in kine on the
node disk. A stolen disk image still yields everything. See the runbook.
