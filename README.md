# export-projects

Dumps Rancher projects and memberships from the management cluster into GitOps-ready YAML. Output is grouped as `<cluster-friendly-name>_<cluster-id>/`, with runtime fields stripped so existing objects can be adopted alongside new GitOps-managed projects.

## Prequisites

These scripts require the following CLI tools and resources:

  * `jq`
  * `yq`
  * `curl`
  * `kubectl`
  * Rancher Management cluster (`local`) Kubeconfig file.
  * Rancher API Token (`RANCHER_TOKEN`). (Optional: Only used for `test.sh`, to validate the scripts)

## Flags

| Flag | Scripts | Description |
| --- | --- | --- |
| `--kubeconfig PATH` | both | Kubeconfig for the Rancher local cluster (default: `local.yaml`, or `KUBECONFIG`) |
| `--rancher-url URL` | both | Rancher URL (default: `https://rancher-manager.somequant.club`, or `RANCHER_URL`) |
| `--out DIR` | both | Output directory (`export.sh`: `export-projects/out`; `test.sh`: `out-test-<timestamp>`) |
| `--cluster ID` | `export.sh` | Limit export to one management cluster ID (repeatable) |
| `-h`, `--help` | both | Show usage |

## Examples

```bash
# All clusters
./export-projects/export.sh \
  --kubeconfig ./local.yaml \
  --rancher-url $RANCHER_URL

# Single cluster
./export-projects/export.sh \
  --kubeconfig ./local.yaml \
  --rancher-url $RANCHER_URL \
  --cluster c-m-88mf69g6 \
  --out ./exported

# Tests scripts: apply of Cluster/Project/Members and export
RANCHER_TOKEN=... ./export-projects/test.sh \
  --kubeconfig ./local.yaml \
  --rancher-url $RANCHER_URL
```
