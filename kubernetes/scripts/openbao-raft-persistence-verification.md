### OpenBao Raft persistence verification

Static regression gate (runs on every `scripts/homelab_test.sh` and in CI IaC lint):

- `python3 scripts/check_openbao_raft_path.py` asserts `server.ha.raft.config`
  keeps the Raft storage path equal to the chart's PVC mount `/openbao/data`
  (and fails if the dead `server.ha.config` block reappears).
- `scripts/homelab_test.sh` additionally asserts the README recovery procedure
  still contains the snapshot save/restore commands, the off-PVC snapshot
  filename, validation commands, and the `/openbao/data` path (and that the
  retired `/vault/data` path is gone).

Run them locally:

```bash
bash scripts/homelab_test.sh
python3 scripts/check_openbao_raft_path.py
```

Both must exit 0 before opening a PR.

---

### Pod-replacement persistence verification (live kind cluster)

This is a single-node Raft deployment (`server.ha.replicas: 1`) whose
StatefulSet pod `openbao-0` mounts `data` (PVC) at `/openbao/data`.

**Prerequisites**

- A live `make up` cluster with OpenBao initialized and unsealed:
  `kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s`
  then `scripts/homelab openbao bootstrap`.
- Working `kubectl` context `kind-${CLUSTER_NAME}`.
- A token that can read and write `secret/` (root token in
  `.runtime-backups/openbao/root-token.txt` works).

**Steps and expected evidence**

1. Prove data is written to the PVC:
   ```bash
   OPENBAO_TOKEN="$(<.runtime-backups/openbao/root-token.txt)"
   kubectl exec -n openbao openbao-0 -- \
     env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
     bao kv put secret/persistence-test key=survives-pod-replacement
   unset OPENBAO_TOKEN
   ```
   Expected: `Success! Data written to: secret/data/persistence-test`.

2. Capture the PVC identity and the pod's replacement epoch:
   ```bash
   PVC_UID="$(kubectl get pvc data-openbao-0 -n openbao -o jsonpath='{.metadata.uid}')"
   POD_EPOCH_BEFORE="$(kubectl get pod openbao-0 -n openbao -o jsonpath='{.metadata.creationTimestamp}')"
   echo "PVC_UID=$PVC_UID POD_EPOCH_BEFORE=$POD_EPOCH_BEFORE"
   ```
   Expected: a non-empty PVC UID; record it for the replacement check.

3. Delete the OpenBao pod (StatefulSet recreates it; the PVC is retained):
   ```bash
   kubectl delete pod openbao-0 -n openbao --wait=false
   kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=300s
   ```
   Expected: the pod is deleted and recreated, `data-openbao-0` PVC is NOT
   deleted (same name/UID), and the pod comes back Ready.

4. Verify the replacement pod is a new pod on the SAME PVC:
   ```bash
   POD_EPOCH_AFTER="$(kubectl get pod openbao-0 -n openbao -o jsonpath='{.metadata.creationTimestamp}')"
   PVC_UID_AFTER="$(kubectl get pvc data-openbao-0 -n openbao -o jsonpath='{.metadata.uid}')"
   echo "POD_EPOCH_AFTER=$POD_EPOCH_AFTER PVC_UID_AFTER=$PVC_UID_AFTER"
   ```
   Expected: `POD_EPOCH_AFTER != POD_EPOCH_BEFORE` (new pod) while
   `PVC_UID_AFTER == PVC_UID` (same PVC).

5. Verify the pre-deletion secret survives on the replacement pod:
   ```bash
   OPENBAO_TOKEN="$(<.runtime-backups/openbao/root-token.txt)"
   kubectl exec -n openbao openbao-0 -- \
     env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
     bao kv get secret/persistence-test
   unset OPENBAO_TOKEN
   ```
   Expected: `key = survives-pod-replacement` is returned. This is the core
   persistence evidence: Raft data written to `/openbao/data` on the PVC
   survived pod replacement.

6. Clean up the test secret:
   ```bash
   OPENBAO_TOKEN="$(<.runtime-backups/openbao/root-token.txt)"
   kubectl exec -n openbao openbao-0 -- \
     env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$OPENBAO_TOKEN" \
     bao kv metadata delete secret/persistence-test
   unset OPENBAO_TOKEN
   ```

**Boundary**

- This verifies pod replacement only. A cluster rebuild (`kind delete cluster`)
  destroys the PVC; recover the data from an independently stored Raft
  snapshot, never from the PVC.
- OpenBao re-seals on restart. If the replacement pod comes back `sealed`,
  unseal with the saved Shamir key:
  `kubectl exec -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 bao operator unseal "$(<.runtime-backups/openbao/unseal-key.txt)"`
