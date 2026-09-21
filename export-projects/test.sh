#!/usr/bin/env bash
# Admin: create dummy custom clusters/projects and grant a no-local-rancher user access.
# No-local-rancher user: export via the Rancher user API, then admin deletes fixtures.
#
# Usage:
#   ./test.sh --rancher-url URL --rancher-token ADMIN_TOKEN
#   NO_LOCAL_RANCHER_TOKEN is loaded from .env (or --no-local-rancher-token).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Create dummy custom clusters and projects as admin, grant the
no-local-rancher user access on those application clusters only (never
local), export with that user's token, then delete the fixtures.

Options:
  --rancher-url URL                 Rancher URL (or RANCHER_URL)
  --rancher-token TOK               Admin API token (or RANCHER_TOKEN)
  --no-local-rancher-token TOK      No-local-rancher API token (or NO_LOCAL_RANCHER_TOKEN)
  --no-local-rancher-user-id ID     Rancher user id to grant (default: m-n9rl5)
  --out DIR               Export output directory (default: ./out-test-<timestamp>)
  -h, --help              Show this help

KEEP_FIXTURES=1 skips cleanup.
EOF
}

NO_LOCAL_RANCHER_USER_ID="${NO_LOCAL_RANCHER_USER_ID:-m-n9rl5}"
NO_LOCAL_RANCHER_USER_PRINCIPAL="local://${NO_LOCAL_RANCHER_USER_ID}"

parse_connection_flags "$@"
if [[ ${#CONNECTION_REST[@]} -gt 0 ]]; then
  set -- "${CONNECTION_REST[@]}"
else
  set --
fi

TEST_OUT_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      TEST_OUT_SET=1
      shift 2
      ;;
    --no-local-rancher-token)
      NO_LOCAL_RANCHER_TOKEN="$2"
      shift 2
      ;;
    --no-local-rancher-token=*)
      NO_LOCAL_RANCHER_TOKEN="${1#*=}"
      shift
      ;;
    --no-local-rancher-user-id)
      NO_LOCAL_RANCHER_USER_ID="$2"
      NO_LOCAL_RANCHER_USER_PRINCIPAL="local://${NO_LOCAL_RANCHER_USER_ID}"
      shift 2
      ;;
    --no-local-rancher-user-id=*)
      NO_LOCAL_RANCHER_USER_ID="${1#*=}"
      NO_LOCAL_RANCHER_USER_PRINCIPAL="local://${NO_LOCAL_RANCHER_USER_ID}"
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

require_cmd curl yq jq

token_identity() {
  local token="$1"
  local body code
  body="$(mktemp)"
  code="$(curl -sS -o "${body}" -w "%{http_code}" ${CURL_INSECURE:+-k} \
    -H "Authorization: Bearer ${token}" -H "Accept: application/json" \
    "${RANCHER_URL%/}/v3/users?me=true" || true)"
  if [[ "${code}" != "200" ]]; then
    rm -f "${body}"
    return 1
  fi
  jq -r '.data[0].username // .data[0].id // empty' "${body}"
  rm -f "${body}"
}

resolve_admin_token() {
  if [[ -n "${RANCHER_TOKEN:-}" ]] && token_identity "${RANCHER_TOKEN}" >/dev/null; then
    return 0
  fi
  local kc="${REPO_ROOT}/local.yaml"
  if [[ -f "${kc}" ]]; then
    local kc_token
    kc_token="$(yq eval -r '.users[0].user.token' "${kc}")"
    if [[ "${kc_token}" == "null" ]]; then
      kc_token=""
    fi
    if [[ -n "${kc_token}" ]] && token_identity "${kc_token}" >/dev/null; then
      echo "warning: RANCHER_TOKEN is missing or unauthorized; using kubeconfig admin token for fixture setup" >&2
      RANCHER_TOKEN="${kc_token}"
      return 0
    fi
  fi
  echo "error: no working admin token (RANCHER_TOKEN / --rancher-token, or local.yaml)" >&2
  exit 1
}

resolve_admin_token
resolve_connection

if [[ -z "${NO_LOCAL_RANCHER_TOKEN:-}" ]]; then
  echo "error: no-local-rancher token is not set (use --no-local-rancher-token or NO_LOCAL_RANCHER_TOKEN in .env)" >&2
  exit 1
fi
if ! no_local_rancher_user="$(token_identity "${NO_LOCAL_RANCHER_TOKEN}")"; then
  echo "error: no-local-rancher token is unauthorized" >&2
  exit 1
fi

RUN_ID="$(date +%Y%m%d%H%M%S)"
NAME_A="npm-xtest-${RUN_ID}-a"
NAME_B="npm-xtest-${RUN_ID}-b"
TEST_LABEL="namespace-projects-migration/test"
PROV_NS="fleet-default"
if [[ "${TEST_OUT_SET}" -eq 0 ]]; then
  OUT_DIR="${SCRIPT_DIR}/out-test-${RUN_ID}"
fi
FIXTURE_PROJECT_DISPLAY="npm-export-fixture"
FIXTURE_PROJECT_NAME="p-npmxtest"
NO_LOCAL_OWNER_BINDING="npm-xtest-limited-owner"
CLEANED_UP=0

PROV_CLUSTERS=("${NAME_A}" "${NAME_B}")
MGMT_IDS=()
PROJECT_NAMES=("p-xtesta" "p-xtestb")
PROJECT_DISPLAYS=("npm-export-fixture-a" "npm-export-fixture-b")
SKIP_CUSTOM_CLUSTERS="${SKIP_CUSTOM_CLUSTERS:-0}"

rke2_version() {
  local ver
  ver="$(rancher_api GET /v1/management.cattle.io.settings/rke2-default-version | jq -r '.value // empty')"
  if [[ -z "${ver}" ]]; then
    ver="v1.31.4+rke2r1"
  elif [[ "${ver}" != v* ]]; then
    ver="v${ver}"
  fi
  printf '%s' "${ver}"
}

create_custom_cluster() {
  local name="$1"
  local version="$2"
  local payload
  payload="$(jq -n \
    --arg name "${name}" \
    --arg version "${version}" \
    --arg label "${TEST_LABEL}" \
    '{
      type: "provisioning.cattle.io.cluster",
      metadata: {
        name: $name,
        namespace: "fleet-default",
        labels: {($label): "true"}
      },
      spec: {
        kubernetesVersion: $version,
        rkeConfig: {
          machineGlobalConfig: {
            cni: "calico",
            "disable-kube-proxy": false,
            "etcd-expose-metrics": false
          },
          machineSelectorConfig: [
            {config: {"protect-kernel-defaults": false}}
          ]
        }
      }
    }')"

  echo "creating custom cluster ${name} (k8s ${version}) via Rancher API"
  rancher_api POST "/v1/provisioning.cattle.io.clusters" -d "${payload}" >/dev/null
}

delete_custom_cluster() {
  local name="$1"
  echo "deleting custom cluster ${name}"
  rancher_api DELETE "/v1/provisioning.cattle.io.clusters/${PROV_NS}/${name}" >/dev/null 2>&1 || true
}

mgmt_id_for_prov() {
  local name="$1"
  rancher_api GET "/v1/provisioning.cattle.io.clusters/${PROV_NS}/${name}" | jq -r '.status.clusterName // empty'
}

has_mgmt_id() {
  local name="$1"
  local id
  id="$(mgmt_id_for_prov "${name}")"
  [[ -n "${id}" && "${id}" != "null" ]]
}

project_count_on() {
  local cluster_id="$1"
  rancher_list /v1/management.cattle.io.projects | jq --arg ns "${cluster_id}" '[.items[] | select(.metadata.namespace == $ns)] | length'
}

has_projects() {
  local cluster_id="$1"
  local count
  count="$(project_count_on "${cluster_id}")"
  [[ "${count}" -ge 1 ]]
}

project_backing_ns() {
  local cluster_id="$1"
  local project_name="$2"
  rancher_api GET "/v1/management.cattle.io.projects/${cluster_id}/${project_name}" | jq -r '.status.backingNamespace // empty'
}

has_backing_ns() {
  local cluster_id="$1"
  local project_name="$2"
  local ns
  ns="$(project_backing_ns "${cluster_id}" "${project_name}")"
  [[ -n "${ns}" && "${ns}" != "null" ]]
}

create_fixture_project() {
  local cluster_id="$1"
  local project_name="$2"
  local display="$3"
  local payload
  payload="$(jq -n \
    --arg name "${project_name}" \
    --arg ns "${cluster_id}" \
    --arg display "${display}" \
    --arg label "${TEST_LABEL}" \
    '{
      type: "management.cattle.io.project",
      apiVersion: "management.cattle.io/v3",
      kind: "Project",
      metadata: {
        name: $name,
        namespace: $ns,
        labels: {($label): "true"},
        annotations: {"field.cattle.io/no-creator-rbac": "true"}
      },
      spec: {
        clusterName: $ns,
        displayName: $display,
        description: "Temporary project used to test export-projects"
      }
    }')"
  rancher_api POST /v1/management.cattle.io.projects -d "${payload}" >/dev/null
}

grant_no_local_rancher_user() {
  local cluster_id="$1"
  local backing_ns="$2"
  local project_name="$3"
  local payload
  payload="$(jq -n \
    --arg ns "${backing_ns}" \
    --arg name "${NO_LOCAL_OWNER_BINDING}" \
    --arg project "${cluster_id}:${project_name}" \
    --arg principal "${NO_LOCAL_RANCHER_USER_PRINCIPAL}" \
    --arg user "${NO_LOCAL_RANCHER_USER_ID}" \
    --arg label "${TEST_LABEL}" \
    '{
      type: "management.cattle.io.projectroletemplatebinding",
      apiVersion: "management.cattle.io/v3",
      kind: "ProjectRoleTemplateBinding",
      metadata: {
        name: $name,
        namespace: $ns,
        labels: {($label): "true"}
      },
      projectName: $project,
      roleTemplateName: "project-owner",
      userName: $user,
      userPrincipalName: $principal
    }')"
  echo "granting ${NO_LOCAL_RANCHER_USER_ID} project-owner on ${cluster_id}:${project_name}"
  rancher_api POST /v1/management.cattle.io.projectroletemplatebindings -d "${payload}" >/dev/null

  payload="$(jq -n \
    --arg ns "${cluster_id}" \
    --arg principal "${NO_LOCAL_RANCHER_USER_PRINCIPAL}" \
    --arg user "${NO_LOCAL_RANCHER_USER_ID}" \
    --arg label "${TEST_LABEL}" \
    '{
      type: "management.cattle.io.clusterroletemplatebinding",
      apiVersion: "management.cattle.io/v3",
      kind: "ClusterRoleTemplateBinding",
      metadata: {
        name: "npm-xtest-limited-cluster",
        namespace: $ns,
        labels: {($label): "true"}
      },
      clusterName: $ns,
      roleTemplateName: "cluster-member",
      userName: $user,
      userPrincipalName: $principal
    }')"
  echo "granting ${NO_LOCAL_RANCHER_USER_ID} cluster-member on ${cluster_id}"
  rancher_api POST /v1/management.cattle.io.clusterroletemplatebindings -d "${payload}" >/dev/null
}

no_local_rancher_sees_cluster_project() {
  local cluster_id="$1"
  local project_name="$2"
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" ${CURL_INSECURE:+-k} \
    -H "Authorization: Bearer ${NO_LOCAL_RANCHER_TOKEN}" -H "Accept: application/json" \
    "${RANCHER_URL}/v3/projects/${cluster_id}:${project_name}" || true)"
  [[ "${code}" == "200" ]]
}

# Leftover from an earlier local-cluster fixture. Prod users never see local.
LOCAL_PROJECT_NAME="p-nsxtest"
LOCAL_NS_NAME="npm-xtest-ns"

revoke_no_local_rancher_local_access() {
  echo "revoking ${NO_LOCAL_RANCHER_USER_ID} access to local"
  rancher_api DELETE /v1/management.cattle.io.clusterroletemplatebindings/local/npm-xtest-limited-cluster >/dev/null 2>&1 || true
  rancher_api DELETE /v1/management.cattle.io.projectroletemplatebindings/local-p-nsxtest/npm-xtest-limited-owner >/dev/null 2>&1 || true
}

no_local_rancher_sees_local() {
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" ${CURL_INSECURE:+-k} \
    -H "Authorization: Bearer ${NO_LOCAL_RANCHER_TOKEN}" -H "Accept: application/json" \
    "${RANCHER_URL}/v3/clusters/local" || true)"
  [[ "${code}" == "200" ]]
}

no_local_rancher_cannot_see_local() {
  if no_local_rancher_sees_local; then
    return 1
  fi
  return 0
}

cleanup_local_namespace_fixture() {
  revoke_no_local_rancher_local_access || true
  rancher_api DELETE "/k8s/clusters/local/api/v1/namespaces/${LOCAL_NS_NAME}" >/dev/null 2>&1 || true
  rancher_api DELETE "/v1/management.cattle.io.projects/local/${LOCAL_PROJECT_NAME}" >/dev/null 2>&1 || true
}

labeled_prov_clusters() {
  rancher_list /v1/provisioning.cattle.io.clusters | jq -r --arg label "${TEST_LABEL}" \
    '.items[] | select(.metadata.labels[$label] == "true") | .metadata.name'
}

cleanup_fixtures() {
  if [[ "${CLEANED_UP}" -eq 1 ]]; then
    return 0
  fi
  # Always drop local grants; prod users never have management-cluster access.
  revoke_no_local_rancher_local_access || true
  if [[ "${KEEP_FIXTURES:-}" == "1" ]]; then
    echo "KEEP_FIXTURES=1; leaving application-cluster fixtures in place"
    CLEANED_UP=1
    return 0
  fi
  echo
  echo "cleaning up test clusters..."
  cleanup_local_namespace_fixture || true
  local name
  for name in "${PROV_CLUSTERS[@]}"; do
    delete_custom_cluster "${name}" || true
  done
  local id
  for id in "${MGMT_IDS[@]+"${MGMT_IDS[@]}"}"; do
    [[ -z "${id}" ]] && continue
    rancher_api DELETE "/v1/management.cattle.io.clusters/${id}" >/dev/null 2>&1 || true
  done
  while IFS= read -r leftover; do
    [[ -z "${leftover}" ]] && continue
    delete_custom_cluster "${leftover}" || true
  done < <(labeled_prov_clusters || true)
  CLEANED_UP=1
}

trap cleanup_fixtures EXIT

echo "rancher-url: ${RANCHER_URL}"
admin_name="$(token_identity "${RANCHER_TOKEN}")"
echo "admin:   ${admin_name}"
echo "no-local-rancher: ${no_local_rancher_user} (${NO_LOCAL_RANCHER_USER_ID})"

# Prove the no-local-rancher user cannot list management-cluster Project CRs.
no_local_k8s_code="$(curl -sS -o /dev/null -w "%{http_code}" ${CURL_INSECURE:+-k} \
  -H "Authorization: Bearer ${NO_LOCAL_RANCHER_TOKEN}" \
  "${RANCHER_URL}/k8s/clusters/local/apis/management.cattle.io/v3/projects" || true)"
echo "no-local-rancher /k8s/clusters/local projects HTTP ${no_local_k8s_code} (expect 403)"
if [[ "${no_local_k8s_code}" != "403" && "${no_local_k8s_code}" != "401" ]]; then
  echo "warning: no-local-rancher user unexpectedly reached the management cluster API (${no_local_k8s_code})" >&2
fi

if [[ "${SKIP_CUSTOM_CLUSTERS}" != "1" ]]; then
  k8s_version="$(rke2_version)"
  create_custom_cluster "${NAME_A}" "${k8s_version}"
  create_custom_cluster "${NAME_B}" "${k8s_version}"

  echo "waiting for management cluster IDs"
  for name in "${PROV_CLUSTERS[@]}"; do
    wait_for "management ID for ${name}" 120 has_mgmt_id "${name}"
    mgmt_id="$(mgmt_id_for_prov "${name}")"
    MGMT_IDS+=("${mgmt_id}")
    echo "  ${name} -> ${mgmt_id}"
    wait_for "projects on ${mgmt_id}" 90 has_projects "${mgmt_id}"
  done

  echo "creating fixture projects and granting ${NO_LOCAL_RANCHER_USER_ID}"
  i=0
  for mgmt_id in "${MGMT_IDS[@]}"; do
    project_name="${PROJECT_NAMES[$i]}"
    project_display="${PROJECT_DISPLAYS[$i]}"
    create_fixture_project "${mgmt_id}" "${project_name}" "${project_display}"
    wait_for "backing namespace for ${project_name}" 60 has_backing_ns "${mgmt_id}" "${project_name}"
    backing_ns="$(project_backing_ns "${mgmt_id}" "${project_name}")"
    grant_no_local_rancher_user "${mgmt_id}" "${backing_ns}" "${project_name}"
    echo "  ${mgmt_id}: project ${project_name} granted in ${backing_ns}"
    i=$((i + 1))
  done

  echo "waiting until no-local-rancher user can see fixture projects"
  sleep 2
  i=0
  for mgmt_id in "${MGMT_IDS[@]}"; do
    wait_for "no-local-rancher project access on ${mgmt_id}:${PROJECT_NAMES[$i]}" 120 no_local_rancher_sees_cluster_project "${mgmt_id}" "${PROJECT_NAMES[$i]}"
    i=$((i + 1))
  done
fi

revoke_no_local_rancher_local_access
wait_for "no-local-rancher user to lose local cluster" 60 no_local_rancher_cannot_see_local
echo "no-local-rancher user cannot see local (expected)"

echo
echo "running no-local-rancher export into ${OUT_DIR}"
"${SCRIPT_DIR}/export.sh" \
  --rancher-url "${RANCHER_URL}" \
  --rancher-token "${NO_LOCAL_RANCHER_TOKEN}" \
  --include-namespaces \
  --out "${OUT_DIR}"

echo
echo "validating no-local-rancher export"
fail=0
assert_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "FAIL: missing ${path}" >&2
    fail=1
    return 1
  fi
  echo "ok  ${path#"${OUT_DIR}"/}"
}

assert_absent() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    echo "FAIL: no-local-rancher export should not include ${path#"${OUT_DIR}"/}" >&2
    fail=1
    return 1
  fi
  echo "ok  absent ${path#"${OUT_DIR}"/}"
}

assert_sanitized() {
  local path="$1"
  if yq eval '.status // .metadata.uid // .metadata.resourceVersion // .metadata.managedFields // .metadata.creationTimestamp // .links // .actions // .id' "${path}" | grep -vq '^null$'; then
    echo "FAIL: ${path} still has runtime fields" >&2
    fail=1
    return 1
  fi
}

if [[ "${SKIP_CUSTOM_CLUSTERS}" != "1" ]]; then
  i=0
  for name in "${PROV_CLUSTERS[@]}"; do
    mgmt_id="${MGMT_IDS[$i]}"
    folder="$(cluster_folder_name "${name}" "${mgmt_id}")"
    cluster_dir="${OUT_DIR}/${folder}"
    project_name="${PROJECT_NAMES[$i]}"
    project_display="${PROJECT_DISPLAYS[$i]}"
    assert_file "${cluster_dir}/cluster.yaml"
    assert_file "${cluster_dir}/projects/${project_display}_${project_name}.yaml"
    assert_file "${cluster_dir}/memberships/${project_name}/${NO_LOCAL_OWNER_BINDING}.yaml"
    while IFS= read -r yaml; do
      [[ -z "${yaml}" ]] && continue
      assert_sanitized "${yaml}"
    done < <(find "${cluster_dir}" -name '*.yaml' -print)
    i=$((i + 1))
  done
fi

# Prod users have no local-cluster membership; export must not include it.
assert_absent "${OUT_DIR}/$(cluster_folder_name local local)"
assert_absent "${OUT_DIR}/$(cluster_folder_name traefik-target c-m-88mf69g6)"
assert_absent "${OUT_DIR}/$(cluster_folder_name nginx-src c-m-xm2j6m9p)"

if [[ "${fail}" -ne 0 ]]; then
  echo "export validation failed" >&2
  exit 1
fi

echo
echo "export validation passed"
echo "tree:"
find "${OUT_DIR}" -print | sed "s|^${OUT_DIR}|  |" | sort

cleanup_fixtures
echo "fixtures removed"
echo "export retained at ${OUT_DIR}"
