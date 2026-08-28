#!/usr/bin/env bash
# Export Rancher Projects and ProjectRoleTemplateBindings, sanitized for GitOps.
#
# Layout:
#   $OUT_DIR/<cluster-friendly-name>_<cluster-id>/
#     cluster.yaml
#     projects/<display-name>_<project-id>.yaml
#     memberships/<project-id>/<prtb-name>.yaml
#
# Usage:
#   ./export.sh --kubeconfig PATH --rancher-url URL [--out DIR] [--cluster CLUSTER_ID]...
#
# Flags override KUBECONFIG / RANCHER_URL when those env vars are also set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Export all Rancher projects (and memberships) from the management cluster.
Cluster folders are named <friendly-name>_<cluster-id>.

Options:
  --kubeconfig PATH  Kubeconfig for the Rancher local/management cluster
                     (default: ${REPO_ROOT}/local.yaml, or KUBECONFIG)
  --rancher-url URL  Rancher URL (default: ${RANCHER_URL}, or RANCHER_URL)
  --out DIR          Output directory (default: ${SCRIPT_DIR}/out)
  --cluster ID       Limit export to one management cluster ID (repeatable)
  -h, --help         Show this help
EOF
}

parse_connection_flags "$@"
if [[ ${#CONNECTION_REST[@]} -gt 0 ]]; then
  set -- "${CONNECTION_REST[@]}"
else
  set --
fi

FILTER_CLUSTERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --cluster)
      FILTER_CLUSTERS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd kubectl yq jq
resolve_connection

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

should_export_cluster() {
  local cluster_id="$1"
  if [[ ${#FILTER_CLUSTERS[@]} -eq 0 ]]; then
    return 0
  fi
  local wanted
  for wanted in "${FILTER_CLUSTERS[@]}"; do
    if [[ "${wanted}" == "${cluster_id}" ]]; then
      return 0
    fi
  done
  return 1
}

echo "kubeconfig:  ${KUBECONFIG}"
echo "rancher-url: ${RANCHER_URL}"
echo "output:      ${OUT_DIR}"

cluster_ids="$(kctl get clusters.management.cattle.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${cluster_ids}" ]]; then
  echo "error: no management clusters found" >&2
  exit 1
fi

exported_projects=0
exported_memberships=0
exported_clusters=0

while IFS= read -r cluster_id; do
  [[ -z "${cluster_id}" ]] && continue
  should_export_cluster "${cluster_id}" || continue

  display_name="$(cluster_display_name "${cluster_id}")"
  folder="$(cluster_folder_name "${display_name}" "${cluster_id}")"
  cluster_dir="${OUT_DIR}/${folder}"
  mkdir -p "${cluster_dir}/projects"

  provider="$(kctl get clusters.management.cattle.io "${cluster_id}" -o jsonpath='{.status.provider}' 2>/dev/null || true)"
  cat > "${cluster_dir}/cluster.yaml" <<EOF
clusterId: ${cluster_id}
displayName: ${display_name}
provider: ${provider:-unknown}
EOF

  echo "cluster ${display_name} (${cluster_id}) -> ${folder}"
  exported_clusters=$((exported_clusters + 1))

  projects_json="$(kctl get projects.management.cattle.io -n "${cluster_id}" -o json 2>/dev/null || echo '{"items":[]}')"
  project_count="$(jq '.items | length' <<<"${projects_json}")"

  if [[ "${project_count}" -eq 0 ]]; then
    echo "  (no projects)"
    continue
  fi

  while IFS= read -r project; do
    project_id="$(jq -r '.metadata.name' <<<"${project}")"
    project_display="$(jq -r '.spec.displayName // .metadata.name' <<<"${project}")"
    backing_ns="$(jq -r '.status.backingNamespace // empty' <<<"${project}")"
    project_file="${cluster_dir}/projects/$(fs_safe "${project_display}")_${project_id}.yaml"

    jq -r '.' <<<"${project}" | yq eval -P '.' | write_sanitized "${project_file}"
    echo "  project ${project_display} (${project_id})"
    exported_projects=$((exported_projects + 1))

    if [[ -z "${backing_ns}" ]]; then
      continue
    fi
    if ! kctl get ns "${backing_ns}" >/dev/null 2>&1; then
      continue
    fi

    prtb_json="$(kctl get projectroletemplatebindings.management.cattle.io -n "${backing_ns}" -o json 2>/dev/null || echo '{"items":[]}')"
    while IFS= read -r prtb; do
      [[ -z "${prtb}" ]] && continue
      prtb_name="$(jq -r '.metadata.name' <<<"${prtb}")"
      prtb_file="${cluster_dir}/memberships/${project_id}/${prtb_name}.yaml"
      jq -r '.' <<<"${prtb}" | yq eval -P '.' | write_sanitized "${prtb_file}"
      echo "    membership ${prtb_name}"
      exported_memberships=$((exported_memberships + 1))
    done < <(jq -c '(.items // [])[]' <<<"${prtb_json}")
  done < <(jq -c '(.items // [])[]' <<<"${projects_json}")
done <<<"${cluster_ids}"

echo
echo "exported ${exported_clusters} cluster(s), ${exported_projects} project(s), ${exported_memberships} membership(s)"
echo "done: ${OUT_DIR}"
