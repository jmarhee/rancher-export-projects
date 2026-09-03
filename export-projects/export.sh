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
#   ./export.sh --rancher-url URL --rancher-token TOKEN [--out DIR] [--cluster CLUSTER_ID]...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Export all Rancher projects (and memberships) via the Rancher API.
Cluster folders are named <friendly-name>_<cluster-id>.

Options:
  --rancher-url URL    Rancher URL (default: ${RANCHER_URL}, or RANCHER_URL)
  --rancher-token TOK  API token (or RANCHER_TOKEN)
  --out DIR            Output directory (default: ${SCRIPT_DIR}/out)
  --cluster ID         Limit export to one management cluster ID (repeatable)
  -h, --help           Show this help
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

require_cmd curl yq jq
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

echo "rancher-url: ${RANCHER_URL}"
echo "output:      ${OUT_DIR}"

clusters_json="$(steve_list /v1/management.cattle.io.clusters)"
projects_json="$(steve_list /v1/management.cattle.io.projects)"
prtbs_json="$(steve_list /v1/management.cattle.io.projectroletemplatebindings)"

cluster_count="$(jq '.items | length' <<<"${clusters_json}")"
if [[ "${cluster_count}" -eq 0 ]]; then
  echo "error: no management clusters found" >&2
  exit 1
fi

exported_projects=0
exported_memberships=0
exported_clusters=0

while IFS= read -r cluster; do
  [[ -z "${cluster}" ]] && continue
  cluster_id="$(jq -r '.metadata.name' <<<"${cluster}")"
  should_export_cluster "${cluster_id}" || continue

  display_name="$(jq -r '.spec.displayName // .metadata.name' <<<"${cluster}")"
  provider="$(jq -r '.status.provider // "unknown"' <<<"${cluster}")"
  folder="$(cluster_folder_name "${display_name}" "${cluster_id}")"
  cluster_dir="${OUT_DIR}/${folder}"
  mkdir -p "${cluster_dir}/projects"

  cat > "${cluster_dir}/cluster.yaml" <<EOF
clusterId: ${cluster_id}
displayName: ${display_name}
provider: ${provider}
EOF

  echo "cluster ${display_name} (${cluster_id}) -> ${folder}"
  exported_clusters=$((exported_clusters + 1))

  cluster_projects="$(jq --arg ns "${cluster_id}" '{items: [.items[] | select(.metadata.namespace == $ns)]}' <<<"${projects_json}")"
  project_count="$(jq '.items | length' <<<"${cluster_projects}")"
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

    while IFS= read -r prtb; do
      [[ -z "${prtb}" ]] && continue
      prtb_name="$(jq -r '.metadata.name' <<<"${prtb}")"
      prtb_file="${cluster_dir}/memberships/${project_id}/${prtb_name}.yaml"
      jq -r '.' <<<"${prtb}" | yq eval -P '.' | write_sanitized "${prtb_file}"
      echo "    membership ${prtb_name}"
      exported_memberships=$((exported_memberships + 1))
    done < <(jq -c --arg ns "${backing_ns}" '.items[] | select(.metadata.namespace == $ns)' <<<"${prtbs_json}")
  done < <(jq -c '.items[]' <<<"${cluster_projects}")
done < <(jq -c '.items[]' <<<"${clusters_json}")

echo
echo "exported ${exported_clusters} cluster(s), ${exported_projects} project(s), ${exported_memberships} membership(s)"
echo "done: ${OUT_DIR}"
