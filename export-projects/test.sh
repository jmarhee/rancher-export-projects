#!/usr/bin/env bash
# Create dummy custom clusters + projects, run export, then delete the fixtures.
#
# Usage:
#   ./test.sh --kubeconfig PATH --rancher-url URL
#   KEEP_FIXTURES=1 ./test.sh --kubeconfig PATH --rancher-url URL
#
# RANCHER_TOKEN remains required in the environment (API bearer token).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Create dummy custom clusters and projects, run export, then delete the fixtures.

Options:
  --kubeconfig PATH  Kubeconfig for the Rancher local/management cluster
                     (default: ${REPO_ROOT}/local.yaml, or KUBECONFIG)
  --rancher-url URL  Rancher URL (default: ${RANCHER_URL}, or RANCHER_URL)
  --out DIR          Export output directory (default: ./out-test-<timestamp>)
  -h, --help         Show this help

RANCHER_TOKEN must be set in the environment.
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

require_cmd kubectl yq jq curl
resolve_connection
if [[ -z "${RANCHER_TOKEN:-}" ]]; then
  echo "error: RANCHER_TOKEN is not set" >&2
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
CLEANED_UP=0

PROV_CLUSTERS=("${NAME_A}" "${NAME_B}")
MGMT_IDS=()

rke2_version() {
  local ver
  ver="$(kctl get setting rke2-default-version -o jsonpath='{.value}')"
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
  local api_err
  api_err="$(mktemp)"
  if rancher_api POST "/v1/provisioning.cattle.io.clusters" -d "${payload}" >"${api_err}" 2>&1; then
    rm -f "${api_err}"
    return 0
  fi
  echo "API create failed:" >&2
  cat "${api_err}" >&2 || true
  rm -f "${api_err}"
  echo "falling back to kubectl" >&2
  kctl apply -f - <<<"$(yq eval -P '.' <<<"${payload}" | yq eval '
    del(.type)
    | .apiVersion = "provisioning.cattle.io/v1"
    | .kind = "Cluster"
  ')"
}

delete_custom_cluster() {
  local name="$1"
  echo "deleting custom cluster ${name}"
  rancher_api DELETE "/v1/provisioning.cattle.io.clusters/${PROV_NS}/${name}" >/dev/null 2>&1 || \
    kctl delete clusters.provisioning.cattle.io -n "${PROV_NS}" "${name}" --ignore-not-found --wait=false
}

mgmt_id_for_prov() {
  local name="$1"
  kctl get clusters.provisioning.cattle.io -n "${PROV_NS}" "${name}" -o jsonpath='{.status.clusterName}'
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
    kctl delete clusters.management.cattle.io "${id}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  local leftover
  leftover="$(kctl get clusters.provisioning.cattle.io -n "${PROV_NS}" -l "${TEST_LABEL}=true" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  while IFS= read -r leftover; do
    [[ -z "${leftover}" ]] && continue
    delete_custom_cluster "${leftover}" || true
  done <<<"${leftover}"
  CLEANED_UP=1
}

trap cleanup_fixtures EXIT

echo "kubeconfig:  ${KUBECONFIG}"
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
  wait_for "management ID for ${name}" 120 bash -c "test -n \"\$(kubectl --kubeconfig '${KUBECONFIG}' get clusters.provisioning.cattle.io -n '${PROV_NS}' '${name}' -o jsonpath='{.status.clusterName}' 2>/dev/null)\""
  mgmt_id="$(mgmt_id_for_prov "${name}")"
  MGMT_IDS+=("${mgmt_id}")
  echo "  ${name} -> ${mgmt_id}"
  wait_for "namespace ${mgmt_id}" 60 kctl get ns "${mgmt_id}"
  wait_for "projects on ${mgmt_id}" 90 bash -c "test \"\$(kubectl --kubeconfig '${KUBECONFIG}' get projects.management.cattle.io -n '${mgmt_id}' --no-headers 2>/dev/null | wc -l | tr -d ' ')\" -ge 1"
done

  echo "creating fixture projects and memberships"
for mgmt_id in "${MGMT_IDS[@]}"; do
  project_name="${FIXTURE_PROJECT_NAME}"
  kctl apply -f - <<EOF
apiVersion: management.cattle.io/v3
kind: Project
metadata:
  name: ${project_name}
  namespace: ${mgmt_id}
  labels:
    ${TEST_LABEL}: "true"
  annotations:
    field.cattle.io/no-creator-rbac: "true"
spec:
  clusterName: ${mgmt_id}
  displayName: ${FIXTURE_PROJECT_DISPLAY}
  description: Temporary project used to test export-projects
EOF
  wait_for "backing namespace for ${project_name}" 60 bash -c "test -n \"\$(kubectl --kubeconfig '${KUBECONFIG}' get projects.management.cattle.io -n '${mgmt_id}' '${project_name}' -o jsonpath='{.status.backingNamespace}' 2>/dev/null)\""
  backing_ns="$(kctl get projects.management.cattle.io -n "${mgmt_id}" "${project_name}" -o jsonpath='{.status.backingNamespace}')"
  wait_for "backing namespace ${backing_ns}" 60 kctl get ns "${backing_ns}"
  kctl apply -f - <<EOF
apiVersion: management.cattle.io/v3
kind: ProjectRoleTemplateBinding
metadata:
  name: npm-xtest-member
  namespace: ${backing_ns}
  labels:
    ${TEST_LABEL}: "true"
projectName: ${mgmt_id}:${project_name}
roleTemplateName: project-member
userPrincipalName: ${principal}
EOF
  echo "  ${mgmt_id}: project ${project_name} + membership in ${backing_ns}"
done

echo
echo "running export into ${OUT_DIR}"
"${SCRIPT_DIR}/export.sh" \
  --kubeconfig "${KUBECONFIG}" \
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
  if yq eval '.status // .metadata.uid // .metadata.resourceVersion // .metadata.managedFields // .metadata.creationTimestamp' "${path}" | grep -vq '^null$'; then
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

# Existing live clusters should still be present in the same export.
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
