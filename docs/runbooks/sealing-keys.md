# Runbook: SealedSecrets keys

Every procedure below was run against a k3d cluster on 2026-08-01 with
controller v0.38.4. The outputs quoted are the observed ones.

## 0. What the key is

On first start the controller generates an RSA-4096 keypair and stores it in
`kube-system` as a `kubernetes.io/tls` Secret labelled
`sealedsecrets.bitnami.com/sealed-secrets-key=active`. The certificate is valid
for ten years. We run with `--key-renew-period=0`, so there is exactly one key
per cluster and it only changes when someone rotates it deliberately. The set
of keys in the cluster is therefore the set you exported at install.

```
$ kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key
NAME                      TYPE                DATA   AGE
sealed-secrets-keyp85jw   kubernetes.io/tls   2      3m39s
```

The controller loads only keys labelled `...sealed-secrets-key=active`. Any
other label value, `compromised` included, means the key is not in the keyring
and blobs sealed against it will not open.

A blob is decryptable by one cluster and, at strict scope, by one name in one
namespace. Nothing in `secrets/` is portable between clusters.

## 1. Install kubeseal

Pinned, with the upstream checksum (upstream's `checksums.txt` covers the
kubeseal tarballs only, not `controller.yaml`; ours is recorded in
`cluster/sealed-secrets/kustomization.yaml`).

```bash
curl -sfLO https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.38.4/kubeseal-0.38.4-linux-amd64.tar.gz
echo "ab5ae808b0efcb167a825b6cf7f3a7c0034bd99a6301d78db2012da651a8c0b9  kubeseal-0.38.4-linux-amd64.tar.gz" | sha256sum -c
tar xzf kubeseal-0.38.4-linux-amd64.tar.gz kubeseal && sudo install kubeseal /usr/local/bin/
```

kubeseal defaults to `--controller-namespace kube-system --controller-name
sealed-secrets-controller`, which is where we install it. No flags needed.

## 2. Back up the key, immediately after install

Do this before sealing anything. The controller has just generated a private
key that exists nowhere else.

```bash
( umask 077
  kubectl get secret -n kube-system \
    -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/<cluster>-sealing-key.yaml )
```

Outside the worktree, and never to the terminal. The default umask writes 0644,
which on the VPS is readable by every local account; `~` keeps the file out of
reach of a `git add -A`, and `.gitignore` covers `*sealing-key*.yaml` as a
backstop, not as the control.

The output is a `v1.List` and is safe to restore with `kubectl apply -f` as it
stands: the recorded `resourceVersion` and `uid` do not block a re-create.

Where it goes: the team vault, one entry per cluster, named for the cluster.
Encrypted before it leaves the machine, or into a vault that encrypts it. Put
the cert fingerprint that `seal-secret.sh fetch-cert` prints in the same entry:
that is what tells you later whether `secrets/<cluster>/pub-cert.pem` still
belongs to the vaulted key.

Where it does **not** go: git, and **not the GitHub org**. Putting the sealing
key in GitHub Actions secrets recreates exactly the exposure this mechanism
exists to remove.

`shred -u ~/<cluster>-sealing-key.yaml` once it is in the vault.

## 3. Verify the backup offline

A backup that has never been decrypted is a hypothesis. Do this once per
cluster, with no cluster contact, against a blob that is actually committed.

```bash
KUBECONFIG=/dev/null kubeseal --recovery-unseal \
  --recovery-private-key ~/<cluster>-sealing-key.yaml \
  < secrets/<cluster>/<namespace>/<name>.yaml -o yaml
```

Expected: a plain `Secret` whose base64 `data` values decode to the values you
sealed. If it errors with `no key could decrypt secret (...)`, the vault entry
does not match the cluster that sealed the blob. Fix that now, not during an
outage.

## 4. Disaster recovery

Order matters, and the wrong order is silently destructive. Restore the key
**before** the controller starts: it adopts the restored key instead of minting
one, and nothing needs restarting.

```bash
# 1. restore the vaulted key. kube-system exists on a fresh cluster and a
#    Secret needs no CRD, so this runs before anything is installed.
kubectl apply -f ~/<cluster>-sealing-key.yaml

# 2. install the controller
kubectl apply -k cluster/sealed-secrets
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s

# 3. only now apply the overlay. It includes secrets/<cluster>/<ns>/, so
#    this step also restores every sealed blob; nothing extra to apply.
kubectl apply -k overlays/<env>
```

Rehearsed on a fresh cluster: one key in `kube-system`, `kubeseal --fetch-cert`
returns the vaulted cert, and a blob sealed against it goes `Synced=True`
without a restart anywhere.

### If the controller started first

`scripts/bootstrap.sh` installs it, so on a rebuilt VPS this is the normal case.
The controller has already minted a key of its own, and the restored one is not
in the keyring.

```bash
kubectl apply -f ~/<cluster>-sealing-key.yaml
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s

# the surplus key is the one kubeseal seals against: remove it, restart again
kubectl -n kube-system delete secret <surplus-key>
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s

# and confirm the committed cert is the vaulted key again
scripts/seal-secret.sh fetch-cert <cluster> --context <ctx> --force
git diff secrets/<cluster>/pub-cert.pem   # expect no change
```

The surplus key is not harmless, and neither half of removing it can be
skipped. kubeseal is served the newest key by `NotBefore`, which is the freshly
minted one, so anything sealed before it is gone is protected by a key that
exists in the cluster and not in the vault. Deleting the Secret does not remove
it from the running controller either: the keyring is built at startup only.
Rehearsed: after `delete secret` with no restart, `--fetch-cert` still returned
the deleted key, a blob sealed against it applied `Synced=True`, and the first
controller restart after that left it `no key could decrypt secret (...)`, with
the private key gone from both the cluster and the vault. Seal nothing until
the surplus key is deleted, the controller restarted, and the cert re-checked.

The restart after a restore is not optional either: restoring the key while the
controller is running has no effect. Rehearsed twice, the SealedSecrets were
still `Synced=False` after the 15 and 20 seconds we waited, and stayed that way.
The controller exhausts its retry budget for a failing SealedSecret in a
fraction of a second (`Error updating, giving up`) and does not reconsider until
it restarts. The `--watch-for-secrets` flag does not remove the restart either:
it registers a key added out of band (`registered private key secretname=...`
appears in the log) but does not re-drive the SealedSecrets that already gave
up. That is why we leave it off.

Verify, either way:

```bash
kubectl get sealedsecrets -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SYNCED:.status.conditions[0].status
```

All `True`. A `False` carries the reason in
`.status.conditions[0].message`.

### The failure is quiet

`kubectl apply` of a SealedSecret that cannot be decrypted **succeeds**. The
resource is created, and the Secret simply never appears:

```
$ kubectl -n <ns> get secret <name>
Error from server (NotFound): secrets "<name>" not found
$ kubectl -n <ns> get sealedsecret <name> -o jsonpath='{.status.conditions[*].message}'
no key could decrypt secret (DUMMY_HOST, DUMMY_TOKEN)
```

Worse, if a Secret of that name was already materialised, it stays at its old
value. Applications keep running on stale data and everything looks fine. Never
read "the app is up" as evidence that a blob decrypted. Read
`.status.conditions`.

## 5. Rotation

Two different things get called rotation, and only one of them helps after a
leak.

- **Value rotation**: change the password, the token, the webhook URL at the
  source, re-seal, commit, apply. This is what a leaked value requires.
- **Sealing-key rotation**: replace the cluster's keypair. It re-encrypts
  nothing on its own, and it does nothing at all for a value that has already
  leaked.

Sealing-key rotation, rehearsed end to end:

```bash
# 1. push the current key out of the keyring so the controller mints a new one
kubectl -n kube-system label secret <old-key> \
  sealedsecrets.bitnami.com/sealed-secrets-key=compromised --overwrite
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s

# 2. put the old key back in the keyring, so both are loaded
kubectl -n kube-system label secret <old-key> \
  sealedsecrets.bitnami.com/sealed-secrets-key=active --overwrite
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=180s

# 3. re-encrypt every committed blob for this cluster to the newest key
scripts/seal-secret.sh fetch-cert <cluster> --context <ctx> --force
for f in $(find secrets/<cluster> -name '*.yaml' ! -name kustomization.yaml); do
  kubeseal --re-encrypt --format yaml < "$f" > "$f.new" \
    && mv "$f.new" "$f" || { rm -f "$f.new"; echo "FAILED: $f"; break; }
done
git commit -am "chore: re-encrypt <cluster> blobs after key rotation"
kubectl apply -k overlays/<env>

# 4. export the new key (section 2) and verify it offline (section 3)

# 5. retire the old key
kubectl -n kube-system delete secret <old-key>
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
```

Notes from the rehearsal:

- Between step 1 and step 2 the old key is out of the keyring, so no existing
  blob can be unsealed. Already-materialised Secrets keep their values and
  running pods are unaffected, but do not apply an overlay in that window. Keep
  it to the two restarts.
- Do not start by deleting the old key. `kubeseal --re-encrypt` asks the
  controller to decrypt with a key it still holds; delete first and step 3
  fails with `error decrypting secret. no key could decrypt secret (...)` and
  the blobs are unrecoverable from the cluster.
- The loop must stop on the first failure and must not reach `kustomization.yaml`.
  Pasted into a shell there is no `set -e`, so a blob that fails to re-encrypt
  is left at its old ciphertext and `git commit -am` cannot tell that run from a
  complete one. `--re-encrypt` on a `kustomization.yaml` exits 1, or exits 0 with
  empty output if the file has no `apiVersion`, and then the `mv` truncates it.
- Step 5 deletes the old key, so before it, every blob must be re-encrypted and
  applied: run the `kubectl get sealedsecrets -A` check from section 4 and
  require `Synced=True` for all of them, not just the one you rehearsed with.
- `--re-encrypt` needs cluster access and the API server's service proxy. It
  changes the ciphertext, not the plaintext, and the result opens with the new
  key alone.

## 6. If the private key is compromised

A leaked private key means every blob ever sealed against that cluster is
readable, including every version in git history. Rotating the key does not
change that.

Rotate the **values**: DB password, JWT secret, both SMTP passwords, the Brevo
key, both Slack webhooks, the GHCR PAT. Re-seal, commit, apply. Then rotate the
sealing key as well (section 5), in that order.

## 7. What this does not protect

SealedSecrets protects the value in transit and in git. It does not encrypt
anything at rest in the cluster.

On single-node k3s the controller writes a plain `Secret`, and both that Secret
and the private key sit unencrypted in kine on the node disk. A stolen disk
image, a VPS snapshot, or root on the node still yields every secret. The
control for that is full-disk encryption, which is a separate decision and has
to be made before the prod VPS carries real data.

Any local account on the node reads them too, and full-disk encryption does
nothing about that: `bootstrap.sh` sets `K3S_KUBECONFIG_MODE=644` so that the
deploy workflow's `ubuntu` user can run `kubectl` without sudo, and that
kubeconfig is `system:masters`. Since this cluster now holds a key that decrypts
every version of every blob in git history, tighten it (0640 plus a group, or a
copy into the operator's `~/.kube/config`) before prod carries real data.

The controller's `secrets-unsealer` ClusterRole grants get/list/create/update/
delete/watch on Secrets in every namespace. Compromising the controller is
equivalent to compromising every Secret in the cluster. That is how the tool
works; do not read SealedSecrets as isolation between namespaces.

Upstream's manifest also binds `system:authenticated` to a Role over the
controller's `services/proxy`, so every ServiceAccount in the cluster, `be` and
`fe` included, can reach the controller's HTTP API through the API server. That
API returns ciphertext, not plaintext, so it is a re-encryption and DoS surface
rather than disclosure. We keep the upstream default.

## 8. Cutover from CI-created Secrets

The state you start from: `deploy.yaml` creates the Secret on every deploy and
the value lives in the GitHub org. Per cluster, per Secret:

1. Install the controller, export and vault the key (section 2), verify it
   offline (section 3).
2. `scripts/seal-secret.sh fetch-cert <cluster> --context <ctx>`, commit the
   cert.
3. Seal each Secret against that cluster from a plaintext file kept outside the
   repo, commit under `secrets/<cluster>/<namespace>/`.
4. **Annotate the existing Secret before applying the SealedSecret**:

   ```bash
   kubectl -n <ns> annotate secret <name> sealedsecrets.bitnami.com/managed=true
   ```

   The controller will not take over a Secret it does not own. Applying the
   SealedSecret first gives you `Synced=False`, reason
   `Resource "<name>" already exists and is not managed by SealedSecret`, while
   `kubectl apply` still exits 0 and the old value stays live. Annotating
   afterwards does not fix it either: the controller has given up, and it
   suppresses re-processing of a SealedSecret whose spec has not changed
   (`update suppressed, no changes in spec`). Recovery from that state is a
   controller restart. Annotating first avoids all of it: rehearsed, the apply
   went straight to `Synced=True` with the new value.

   Deleting the existing Secret instead of annotating it also works, at the
   cost of a window in which the Secret does not exist.
5. Apply, then check both that it synced and that the values are the ones CI was
   setting. Not `kubectl apply` output, and `Synced=True` only proves that the
   ciphertext round-tripped:

   ```bash
   # before step 4, while the CI-created Secret is still live
   kubectl -n <ns> get secret <name> -o jsonpath='{.data}' | sha256sum

   # after applying the SealedSecret
   kubectl -n <ns> get sealedsecret <name> -o jsonpath='{.status.conditions[*].status}'
   kubectl -n <ns> get secret <name> -o jsonpath='{.data}' | sha256sum
   ```

   Same digest, or a diff you can account for key by key. `--from-env-file` is a
   literal parser: a value transcribed with its quotes or a trailing space seals,
   applies and syncs exactly like a correct one, and step 6 then deletes the last
   copy of the right value.
6. Only then remove that `kubectl create secret` block from
   `.github/workflows/deploy.yaml`, and only then delete the corresponding
   GitHub Actions secret from the org. That last deletion is where this work
   actually pays off.

AITS carries both `n4d-dev` and `n4d-pre` under one key, so a blob for either
namespace lives under the same cluster directory and is sealed against the same
cert.
