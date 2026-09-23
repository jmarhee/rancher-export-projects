#!/usr/bin/env bash
# Export Rancher Projects and ProjectRoleTemplateBindings, sanitized for GitOps.
#
# Uses the Rancher user API (/v3) so the token only needs access to the
# clusters and projects it can already see. It does not call the management
# cluster Kubernetes API (/k8s/clusters/local/...).
#
# Layout:
#   $OUT_DIR/<cluster-friendly-name>_<cluster-id>/
#     cluster.yaml
#     projects/<display-name>_<project-id>.yaml
#     memberships/<project-id>/<prtb-name>.yaml
#     namespaces/<ns>.yaml                         (--include-namespaces)
#     namespaces/<ns>/rolebindings/<name>.yaml
#     namespaces/<ns>/roles/<name>.yaml
#
# Usage:
#   ./export.sh --rancher-url URL --rancher-token TOKEN [--include-namespaces] [--out DIR] [--cluster ID|NAME]... [--cluster-file FILE] [--jobs N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Export Rancher projects and memberships the API token can access.
Does not require management-cluster kubectl/RBAC. Cluster folders are
named <friendly-name>_<cluster-id>.

Options:
  --rancher-url URL    Rancher URL (default: ${RANCHER_URL}, or RANCHER_URL)
  --rancher-token TOK  API token (or RANCHER_TOKEN)
  --out DIR              Output directory (default: ${SCRIPT_DIR}/out)
  --cluster ID|NAME      Limit export to one cluster ID or friendly name (repeatable)
  --cluster-name NAME    Same as --cluster (repeatable)
  --cluster-file FILE    Cluster IDs or names, one per line (repeatable; # comments ok)
  --jobs N               Export up to N clusters at once (default: 1)
  --parallel N           Same as --jobs
  --include-namespaces   Also export project namespaces and their Roles/RoleBindings
  -h, --help             Show this help
EOF
}

parse_connection_flags "$@"
if [[ ${#CONNECTION_REST[@]} -gt 0 ]]; then
  set -- "${CONNECTION_REST[@]}"
else
  set --
fi

FILTER_CLUSTERS=()
CLUSTER_FILES=()
INCLUDE_NAMESPACES=0
JOBS="${JOBS:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --cluster|--cluster-name)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a cluster ID or friendly name" >&2
        exit 1
      fi
      FILTER_CLUSTERS+=("$2")
      shift 2
      ;;
    --cluster=*|--cluster-name=*)
      FILTER_CLUSTERS+=("${1#*=}")
      shift
      ;;
    --cluster-file)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a file path" >&2
        exit 1
      fi
      CLUSTER_FILES+=("$2")
      shift 2
      ;;
    --cluster-file=*)
      CLUSTER_FILES+=("${1#*=}")
      shift
      ;;
    --jobs|--parallel)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a positive integer" >&2
        exit 1
      fi
      JOBS="$2"
      shift 2
      ;;
    --jobs=*|--parallel=*)
      JOBS="${1#*=}"
      shift
      ;;
    --include-namespaces)
      INCLUDE_NAMESPACES=1
      shift
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

load_cluster_file() {
  local file="$1" line
  if [[ ! -f "${file}" ]]; then
    echo "error: cluster file not found: ${file}" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    FILTER_CLUSTERS+=("${line}")
  done <"${file}"
}

for cluster_file in ${CLUSTER_FILES[@]+"${CLUSTER_FILES[@]}"}; do
  load_cluster_file "${cluster_file}"
done

if ! [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --jobs must be a positive integer (got ${JOBS})" >&2
  exit 1
fi

require_cmd curl yq jq
resolve_connection

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

should_export_cluster() {
  local cluster_id="$1"
  local cluster_name="$2"
  if [[ ${#FILTER_CLUSTERS[@]} -eq 0 ]]; then
    return 0
  fi
  local wanted
  for wanted in "${FILTER_CLUSTERS[@]}"; do
    if [[ "${wanted}" == "${cluster_id}" || "${wanted}" == "${cluster_name}" ]]; then
      return 0
    fi
  done
  return 1
}

echo "rancher-url: ${RANCHER_URL}"
echo "output:      ${OUT_DIR}"
if [[ "${JOBS}" -gt 1 ]]; then
  echo "jobs:        ${JOBS}"
fi

# User-scoped Norman APIs: filtered to what this token can see, no local-cluster list RBAC.
# Write collections to files so jq never hits ARG_MAX (--argjson puts JSON on argv).
clusters_file="$(mktemp)"
projects_file="$(mktemp)"
work_dir=""
cleanup_export_tmp() {
  [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] || return 0
  rm -f "${clusters_file}" "${projects_file}"
  if [[ -n "${work_dir}" ]]; then
    rm -rf "${work_dir}"
  fi
}
trap cleanup_export_tmp EXIT
rancher_list /v3/clusters >"${clusters_file}"
rancher_list /v3/projects >"${projects_file}"

cluster_ids="$(jq -r -s '
  ([.[0].items // [] | .[].id] + [.[1].items // [] | .[].clusterId] | unique | .[])
' "${clusters_file}" "${projects_file}")"

if [[ -z "${cluster_ids}" ]]; then
  echo "error: no clusters or projects visible to this token" >&2
  exit 1
fi

export_namespaces_for_cluster() {
  local cluster_id="$1"
  local cluster_dir="$2"
  shift 2
  local project_ids=("$@")
  local ns_json ns_name project_id k8s_ns rb_json role_json rb role

  if [[ ${#project_ids[@]} -eq 0 ]]; then
    return 0
  fi

  if ! ns_json="$(rancher_list "/v3/clusters/${cluster_id}/namespaces" 2>/dev/null)"; then
    echo "    (cluster unavailable; skipping namespaces)"
    return 0
  fi

  while IFS= read -r ns; do
    [[ -z "${ns}" ]] && continue
    project_id="$(jq -r '.projectId // empty' <<<"${ns}")"
    local match=0
    local wanted
    for wanted in "${project_ids[@]}"; do
      if [[ "${project_id}" == "${wanted}" ]]; then
        match=1
        break
      fi
    done
    if [[ "${match}" -eq 0 ]]; then
      continue
    fi

    ns_name="$(jq -r '.name // .id' <<<"${ns}")"
    k8s_ns="$(k8s_get "/k8s/clusters/${cluster_id}/api/v1/namespaces/${ns_name}" 2>/dev/null || true)"
    if [[ -n "${k8s_ns}" ]] && jq -e '.kind == "Namespace"' <<<"${k8s_ns}" >/dev/null 2>&1; then
      jq -c '.' <<<"${k8s_ns}" | yq eval -P '.' | write_sanitized "${cluster_dir}/namespaces/${ns_name}.yaml"
    else
      jq -c '.' <<<"${ns}" | norman_namespace_to_k8s | yq eval -P '.' | write_sanitized "${cluster_dir}/namespaces/${ns_name}.yaml"
    fi
    echo "    namespace ${ns_name}"
    exported_namespaces=$((exported_namespaces + 1))

    rb_json="$(k8s_list "/k8s/clusters/${cluster_id}/apis/rbac.authorization.k8s.io/v1/namespaces/${ns_name}/rolebindings")"
    while IFS= read -r rb; do
      [[ -z "${rb}" ]] && continue
      local rb_name
      rb_name="$(jq -r '.metadata.name' <<<"${rb}")"
      jq -c '.' <<<"${rb}" | ensure_gvk rbac.authorization.k8s.io/v1 RoleBinding | yq eval -P '.' | write_sanitized "${cluster_dir}/namespaces/${ns_name}/rolebindings/${rb_name}.yaml"
      echo "      rolebinding ${rb_name}"
      exported_rolebindings=$((exported_rolebindings + 1))
    done < <(jq -c '(.items // [])[]' <<<"${rb_json}")

    role_json="$(k8s_list "/k8s/clusters/${cluster_id}/apis/rbac.authorization.k8s.io/v1/namespaces/${ns_name}/roles")"
    while IFS= read -r role; do
      [[ -z "${role}" ]] && continue
      local role_name
      role_name="$(jq -r '.metadata.name' <<<"${role}")"
      jq -c '.' <<<"${role}" | ensure_gvk rbac.authorization.k8s.io/v1 Role | yq eval -P '.' | write_sanitized "${cluster_dir}/namespaces/${ns_name}/roles/${role_name}.yaml"
      echo "      role ${role_name}"
      exported_roles=$((exported_roles + 1))
    done < <(jq -c '(.items // [])[]' <<<"${role_json}")
  done < <(jq -c '(.items // [])[]' <<<"${ns_json}")
}

write_export_counts() {
  local dest="$1"
  cat >"${dest}" <<EOF
clusters=${exported_clusters}
projects=${exported_projects}
memberships=${exported_memberships}
namespaces=${exported_namespaces}
rolebindings=${exported_rolebindings}
roles=${exported_roles}
EOF
}

export_one_cluster() {
  local cluster_id="$1"
  local counts_file="${2:-}"
  local cluster display_name provider folder cluster_dir
  local cluster_projects project_count cluster_project_ids=()
  local project project_id project_display backing_ns project_file
  local prtb_json prtb prtb_name prtb_file
  local exported_clusters=0 exported_projects=0 exported_memberships=0
  local exported_namespaces=0 exported_rolebindings=0 exported_roles=0

  cluster="$(jq -c --arg id "${cluster_id}" '.items[] | select(.id == $id)' "${clusters_file}")"
  if [[ -z "${cluster}" ]]; then
    cluster="$(rancher_request GET "/v3/clusters/${cluster_id}" 2>/dev/null || echo '{}')"
  fi
  display_name="$(jq -r '.name // .id // empty' <<<"${cluster}")"
  if [[ -z "${display_name}" ]]; then
    display_name="${cluster_id}"
  fi
  if ! should_export_cluster "${cluster_id}" "${display_name}"; then
    [[ -n "${counts_file}" ]] && write_export_counts "${counts_file}"
    return 0
  fi
  provider="$(jq -r '.provider // "unknown"' <<<"${cluster}")"

  folder="$(cluster_folder_name "${display_name}" "${cluster_id}")"
  cluster_dir="${OUT_DIR}/${folder}"
  mkdir -p "${cluster_dir}/projects"

  cat > "${cluster_dir}/cluster.yaml" <<EOF
clusterId: ${cluster_id}
displayName: ${display_name}
provider: ${provider}
EOF

  echo "cluster ${display_name} (${cluster_id}) -> ${folder}"
  exported_clusters=1

  # Always query by clusterId. The unfiltered /v3/projects collection can omit
  # downstream projects depending on token scope.
  cluster_projects="$(rancher_list "/v3/projects?clusterId=${cluster_id}")"
  if [[ "$(jq '.items | length' <<<"${cluster_projects}")" -eq 0 ]]; then
    cluster_projects="$(jq -c --arg id "${cluster_id}" '{items: [.items[] | select(.clusterId == $id)]}' "${projects_file}")"
  fi

  project_count="$(jq '.items | length' <<<"${cluster_projects}")"
  if [[ "${project_count}" -eq 0 ]]; then
    echo "  (no projects)"
    [[ -n "${counts_file}" ]] && write_export_counts "${counts_file}"
    return 0
  fi

  while IFS= read -r project; do
    project_id="$(jq -r '.id | split(":")[1]' <<<"${project}")"
    project_display="$(jq -r '.name // empty' <<<"${project}")"
    backing_ns="$(jq -r '.backingNamespace // empty' <<<"${project}")"
    project_file="${cluster_dir}/projects/$(fs_safe "${project_display:-$project_id}")_${project_id}.yaml"

    jq -c '.' <<<"${project}" | norman_project_to_k8s | yq eval -P '.' | write_sanitized "${project_file}"
    echo "  project ${project_display} (${project_id})"
    exported_projects=$((exported_projects + 1))
    cluster_project_ids+=("${cluster_id}:${project_id}")

    if [[ -z "${backing_ns}" ]]; then
      continue
    fi

    prtb_json="$(rancher_list "/v3/projects/${cluster_id}:${project_id}/projectroletemplatebindings" 2>/dev/null || echo '{"items":[]}')"
    while IFS= read -r prtb; do
      [[ -z "${prtb}" ]] && continue
      prtb_name="$(jq -r '.name // (.id | split(":")[-1])' <<<"${prtb}")"
      prtb_file="${cluster_dir}/memberships/${project_id}/${prtb_name}.yaml"
      jq -c '.' <<<"${prtb}" | norman_prtb_to_k8s "${backing_ns}" | yq eval -P '.' | write_sanitized "${prtb_file}"
      echo "    membership ${prtb_name}"
      exported_memberships=$((exported_memberships + 1))
    done < <(jq -c '(.items // [])[]' <<<"${prtb_json}")
  done < <(jq -c '.items[]' <<<"${cluster_projects}")

  if [[ "${INCLUDE_NAMESPACES}" -eq 1 ]]; then
    export_namespaces_for_cluster "${cluster_id}" "${cluster_dir}" ${cluster_project_ids[@]+"${cluster_project_ids[@]}"}
  fi

  [[ -n "${counts_file}" ]] && write_export_counts "${counts_file}"
}

reap_finished_jobs() {
  local pid still=()
  for pid in ${running_pids[@]+"${running_pids[@]}"}; do
    if kill -0 "${pid}" 2>/dev/null; then
      still+=("${pid}")
    else
      if ! wait "${pid}"; then
        job_failed=1
      fi
    fi
  done
  running_pids=("${still[@]+"${still[@]}"}")
}

wait_for_job_slot() {
  while (( ${#running_pids[@]} >= JOBS )); do
    sleep 0.2
    reap_finished_jobs
  done
}

count_field() {
  local file="$1" key="$2" value
  value="$(sed -n "s/^${key}=//p" "${file}")"
  printf '%s' "${value:-0}"
}

add_counts_from_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  exported_clusters=$((exported_clusters + $(count_field "${file}" clusters)))
  exported_projects=$((exported_projects + $(count_field "${file}" projects)))
  exported_memberships=$((exported_memberships + $(count_field "${file}" memberships)))
  exported_namespaces=$((exported_namespaces + $(count_field "${file}" namespaces)))
  exported_rolebindings=$((exported_rolebindings + $(count_field "${file}" rolebindings)))
  exported_roles=$((exported_roles + $(count_field "${file}" roles)))
}

exported_projects=0
exported_memberships=0
exported_clusters=0
exported_namespaces=0
exported_rolebindings=0
exported_roles=0
job_failed=0
running_pids=()
work_dir="$(mktemp -d)"
job_idx=0

while IFS= read -r cluster_id; do
  [[ -z "${cluster_id}" ]] && continue
  if [[ "${JOBS}" -eq 1 ]]; then
    export_one_cluster "${cluster_id}" "${work_dir}/${job_idx}.counts"
    add_counts_from_file "${work_dir}/${job_idx}.counts"
  else
    wait_for_job_slot
    (
      export_one_cluster "${cluster_id}" "${work_dir}/${job_idx}.counts"
    ) >"${work_dir}/${job_idx}.log" 2>&1 &
    running_pids+=("$!")
  fi
  job_idx=$((job_idx + 1))
done <<<"${cluster_ids}"

if [[ "${JOBS}" -gt 1 ]]; then
  while (( ${#running_pids[@]} > 0 )); do
    sleep 0.2
    reap_finished_jobs
  done
  i=0
  while (( i < job_idx )); do
    if [[ -f "${work_dir}/${i}.log" ]]; then
      cat "${work_dir}/${i}.log"
    fi
    add_counts_from_file "${work_dir}/${i}.counts"
    i=$((i + 1))
  done
fi

if [[ "${job_failed}" -ne 0 ]]; then
  echo "error: one or more cluster exports failed" >&2
  exit 1
fi

if [[ ${#FILTER_CLUSTERS[@]} -gt 0 && "${exported_clusters}" -eq 0 ]]; then
  echo "error: no visible clusters matched: ${FILTER_CLUSTERS[*]}" >&2
  exit 1
fi

echo
if [[ "${INCLUDE_NAMESPACES}" -eq 1 ]]; then
  echo "exported ${exported_clusters} cluster(s), ${exported_projects} project(s), ${exported_memberships} membership(s), ${exported_namespaces} namespace(s), ${exported_rolebindings} rolebinding(s), ${exported_roles} role(s)"
else
  echo "exported ${exported_clusters} cluster(s), ${exported_projects} project(s), ${exported_memberships} membership(s)"
fi
echo "done: ${OUT_DIR}"
