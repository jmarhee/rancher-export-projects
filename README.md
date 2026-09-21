# export-projects

Dumps Rancher projects and memberships the API token can access into GitOps-ready YAML. Uses the Rancher user API (`/v3`), not the management-cluster Kubernetes API, so a project member token is enough. The token only sees application clusters it is a member of, not via `local`. Output is grouped as `<cluster-friendly-name>_<cluster-id>/`.

Requires `curl`, `jq`, `yq`, and a Rancher API token.

## Flags

| Flag | Scripts | Description |
| --- | --- | --- |
| `--rancher-url URL` | both | Rancher URL (or `RANCHER_URL`) |
| `--rancher-token TOK` | both | API token used to export (`export.sh`) or admin token for fixtures (`test.sh`) |
| `--no-local-rancher-token TOK` | `test.sh` | Token for the no-local-rancher user (or `NO_LOCAL_RANCHER_TOKEN` in `.env`) |
| `--no-local-rancher-user-id ID` | `test.sh` | User to grant fixture access (default: `m-n9rl5`) |
| `--out DIR` | both | Output directory |
| `--cluster ID` | `export.sh` | Limit export to one cluster ID (repeatable) |
| `--include-namespaces` | `export.sh` | Also export project namespaces and their Roles/RoleBindings |
| `-h`, `--help` | both | Show usage |

## Examples

```bash
# Export clusters/projects this token can see
./export-projects/export.sh \
  --rancher-url "$RANCHER_URL" \
  --rancher-token "$NO_LOCAL_RANCHER_TOKEN" \
  --include-namespaces

# Admin creates blank custom clusters, grants the no-local-rancher user, exports as that user, then cleans up
./export-projects/test.sh \
  --rancher-url "$RANCHER_URL" \
  --rancher-token "$RANCHER_TOKEN"
```
