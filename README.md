# export-projects

Dumps Rancher projects and memberships into GitOps-ready YAML using the Rancher API (no kubectl or kubeconfig). Output is grouped as `<cluster-friendly-name>_<cluster-id>/`, with runtime fields stripped so existing objects can be adopted alongside new GitOps-managed projects.

Requires `curl`, `jq`, `yq`, and a Rancher API token.

## Flags

| Flag | Scripts | Description |
| --- | --- | --- |
| `--rancher-url URL` | both | Rancher URL (default: `https://rancher-manager.somequant.club`, or `RANCHER_URL`) |
| `--rancher-token TOK` | both | API token (or `RANCHER_TOKEN`) |
| `--out DIR` | both | Output directory (`export.sh`: `export-projects/out`; `test.sh`: `out-test-<timestamp>`) |
| `--cluster ID` | `export.sh` | Limit export to one management cluster ID (repeatable) |
| `-h`, `--help` | both | Show usage |

## Examples

```bash
# All clusters
./export-projects/export.sh \
  --rancher-url "$RANCHER_URL" \
  --rancher-token "$RANCHER_TOKEN"

# Single cluster
./export-projects/export.sh \
  --rancher-url "$RANCHER_URL" \
  --rancher-token "$RANCHER_TOKEN" \
  --cluster c-m-88mf69g6 \
  --out ./exported

# Create fixture clusters/projects, export, then delete fixtures
./export-projects/test.sh \
  --rancher-url "$RANCHER_URL" \
  --rancher-token "$RANCHER_TOKEN"
```
