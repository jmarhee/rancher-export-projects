#!/usr/bin/env bash
# Create dummy custom clusters + projects via the Rancher API, run export, then
# delete the fixtures.
#
# Usage:
#   ./test.sh --rancher-url URL --rancher-token TOKEN
#   KEEP_FIXTURES=1 ./test.sh --rancher-url URL --rancher-token TOKEN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Create dummy custom clusters and projects via the Rancher API, run export,
then delete the fixtures.

Options:
  --rancher-url URL    Rancher URL (default: ${RANCHER_URL}, or RANCHER_URL)
  --rancher-token TOK  API token (or RANCHER_TOKEN)
  --out DIR            Export output directory (default: ./out-test-<timestamp>)
  -h, --help           Show this help

KEEP_FIXTURES=1 skips cleanup.
EOF
}

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
CLEANED_UP=0

PROV_CLUSTERS=("${NAME_A}" "${NAME_B}")
MGMT_IDS=()

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

current_user_principal() {
  rancher_api GET "/v3/users?me=true" | jq -r '.data[0].principalIds[0] // empty'
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
  steve_list /v1/management.cattle.io.projects | jq --arg ns "${cluster_id}" '[.items[] | select(.metadata.namespace == $ns)] | length'
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
  local payload
  payload="$(jq -n \
    --arg name "${FIXTURE_PROJECT_NAME}" \
    --arg ns "${cluster_id}" \
    --arg display "${FIXTURE_PROJECT_DISPLAY}" \
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

create_fixture_membership() {
  local cluster_id="$1"
  local backing_ns="$2"
  local principal="$3"
  local payload
  payload="$(jq -n \
    --arg ns "${backing_ns}" \
    --arg project "${cluster_id}:${FIXTURE_PROJECT_NAME}" \
    --arg principal "${principal}" \
    --arg label "${TEST_LABEL}" \
    '{
      type: "management.cattle.io.projectroletemplatebinding",
      apiVersion: "management.cattle.io/v3",
      kind: "ProjectRoleTemplateBinding",
      metadata: {
        name: "npm-xtest-member",
        namespace: $ns,
        labels: {($label): "true"}
      },
      projectName: $project,
      roleTemplateName: "project-member",
      userPrincipalName: $principal
    }')"
  rancher_api POST /v1/management.cattle.io.projectroletemplatebindings -d "${payload}" >/dev/null
}

labeled_prov_clusters() {
  steve_list /v1/provisioning.cattle.io.clusters | jq -r --arg label "${TEST_LABEL}" \
    '.items[] | select(.metadata.labels[$label] == "true") | .metadata.name'
}

cleanup_fixtures() {
  if [[ "${CLEANED_UP}" -eq 1 ]]; then
    return 0
  fi
  if [[ "${KEEP_FIXTURES:-}" == "1" ]]; then
    echo "KEEP_FIXTURES=1; leaving test clusters in place"
    CLEANED_UP=1
    return 0
  fi
  echo
  echo "cleaning up test clusters..."
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
echo "verifying Rancher API auth"
me="$(rancher_api GET "/v3/users?me=true" | jq -r '.data[0].username // .data[0].id')"
echo "authenticated as ${me}"
principal="$(current_user_principal)"
if [[ -z "${principal}" ]]; then
  echo "error: could not resolve current user principal" >&2
  exit 1
fi

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

echo "creating fixture projects and memberships"
for mgmt_id in "${MGMT_IDS[@]}"; do
  create_fixture_project "${mgmt_id}"
  wait_for "backing namespace for ${FIXTURE_PROJECT_NAME}" 60 has_backing_ns "${mgmt_id}" "${FIXTURE_PROJECT_NAME}"
  backing_ns="$(project_backing_ns "${mgmt_id}" "${FIXTURE_PROJECT_NAME}")"
  create_fixture_membership "${mgmt_id}" "${backing_ns}" "${principal}"
  echo "  ${mgmt_id}: project ${FIXTURE_PROJECT_NAME} + membership in ${backing_ns}"
done

echo
echo "running export into ${OUT_DIR}"
"${SCRIPT_DIR}/export.sh" \
  --rancher-url "${RANCHER_URL}" \
  --out "${OUT_DIR}"

echo
echo "validating export"
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

assert_sanitized() {
  local path="$1"
  if yq eval '.status // .metadata.uid // .metadata.resourceVersion // .metadata.managedFields // .metadata.creationTimestamp // .links // .actions // .id' "${path}" | grep -vq '^null$'; then
    echo "FAIL: ${path} still has runtime fields" >&2
    fail=1
    return 1
  fi
}

i=0
for name in "${PROV_CLUSTERS[@]}"; do
  mgmt_id="${MGMT_IDS[$i]}"
  folder="$(cluster_folder_name "${name}" "${mgmt_id}")"
  cluster_dir="${OUT_DIR}/${folder}"
  assert_file "${cluster_dir}/cluster.yaml"
  assert_file "${cluster_dir}/projects/${FIXTURE_PROJECT_DISPLAY}_${FIXTURE_PROJECT_NAME}.yaml"
  assert_file "${cluster_dir}/memberships/${FIXTURE_PROJECT_NAME}/npm-xtest-member.yaml"
  while IFS= read -r yaml; do
    [[ -z "${yaml}" ]] && continue
    assert_sanitized "${yaml}"
  done < <(find "${cluster_dir}" -name '*.yaml' -print)
  i=$((i + 1))
done

assert_file "${OUT_DIR}/$(cluster_folder_name traefik-target c-m-88mf69g6)/cluster.yaml" || true
assert_file "${OUT_DIR}/$(cluster_folder_name nginx-src c-m-xm2j6m9p)/cluster.yaml" || true
assert_file "${OUT_DIR}/$(cluster_folder_name local local)/cluster.yaml" || true

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
