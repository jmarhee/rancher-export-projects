#!/usr/bin/env bash
# Shared helpers for Rancher project export (Rancher HTTP API only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${RANCHER_URL:=https://rancher-manager.somequant.club}"
: "${OUT_DIR:=${SCRIPT_DIR}/out}"

load_repo_env() {
  local env_file="${REPO_ROOT}/.env"
  [[ -f "${env_file}" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
}

load_repo_env

# Pull connection flags off the argument list. Remaining flags are left in
# CONNECTION_REST for the caller to parse.
parse_connection_flags() {
  CONNECTION_REST=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig|--kubeconfig=*)
        echo "error: --kubeconfig is no longer used; pass --rancher-token or set RANCHER_TOKEN" >&2
        exit 1
        ;;
      --rancher-url)
        if [[ $# -lt 2 ]]; then
          echo "error: $1 requires a URL" >&2
          exit 1
        fi
        RANCHER_URL="$2"
        shift 2
        ;;
      --rancher-url=*)
        RANCHER_URL="${1#*=}"
        shift
        ;;
      --rancher-token)
        if [[ $# -lt 2 ]]; then
          echo "error: $1 requires a token" >&2
          exit 1
        fi
        RANCHER_TOKEN="$2"
        shift 2
        ;;
      --rancher-token=*)
        RANCHER_TOKEN="${1#*=}"
        shift
        ;;
      *)
        CONNECTION_REST+=("$1")
        shift
        ;;
    esac
  done
}

resolve_connection() {
  if [[ -z "${RANCHER_URL:-}" ]]; then
    echo "error: Rancher URL is not set (use --rancher-url or RANCHER_URL)" >&2
    exit 1
  fi
  if [[ -z "${RANCHER_TOKEN:-}" ]]; then
    echo "error: Rancher API token is not set (use --rancher-token or RANCHER_TOKEN)" >&2
    exit 1
  fi
  RANCHER_URL="${RANCHER_URL%/}"
  export RANCHER_URL RANCHER_TOKEN
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || {
      echo "error: required command not found: ${cmd}" >&2
      exit 1
    }
  done
}

# GET/POST/DELETE against a Rancher path or absolute URL.
rancher_request() {
  local method="$1"
  local url="$2"
  shift 2
  if [[ -z "${RANCHER_TOKEN:-}" ]]; then
    echo "error: RANCHER_TOKEN is not set" >&2
    exit 1
  fi
  case "${url}" in
    http://*|https://*) ;;
    *) url="${RANCHER_URL%/}${url}" ;;
  esac
  curl -sS --fail ${CURL_INSECURE:+-k} \
    -X "${method}" \
    -H "Authorization: Bearer ${RANCHER_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@" \
    "${url}"
}

rancher_api() {
  rancher_request "$@"
}

# List a Steve or Norman collection, following pagination.next. Prints {items:[...]}.
rancher_list() {
  local path="$1"
  local tmp page next
  tmp="$(mktemp)"
  printf '%s\n' '[]' >"${tmp}"
  next="${path}"
  while [[ -n "${next}" ]]; do
    page="$(rancher_request GET "${next}")"
    jq -s '.[0] + (.[1].data // [])' "${tmp}" <(printf '%s' "${page}") >"${tmp}.n"
    mv "${tmp}.n" "${tmp}"
    next="$(jq -r '.pagination.next // empty' <<<"${page}")"
  done
  jq '{items: .}' "${tmp}"
  rm -f "${tmp}"
}

steve_list() {
  rancher_list "$@"
}

# Kubernetes List from the Rancher cluster proxy ({items:[...]}).
k8s_list() {
  local path="$1"
  local page
  if ! page="$(rancher_request GET "${path}" 2>/dev/null)"; then
    echo '{"items":[]}'
    return 0
  fi
  jq '{items: (.items // [])}' <<<"${page}"
}

k8s_get() {
  local path="$1"
  rancher_request GET "${path}"
}

# List items often omit apiVersion/kind; restore them for GitOps apply.
ensure_gvk() {
  local api_version="$1"
  local kind="$2"
  jq --arg api "${api_version}" --arg kind "${kind}" '
    .apiVersion = (.apiVersion // $api) | .kind = (.kind // $kind)
  '
}

# Norman namespace -> core/v1 Namespace JSON.
norman_namespace_to_k8s() {
  jq '{
    apiVersion: "v1",
    kind: "Namespace",
    metadata: (
      {
        name: .name
      }
      + {
          annotations: (
            (.annotations // {})
            + if ((.projectId // "") != "") then {"field.cattle.io/projectId": .projectId} else {} end
          )
        }
      + {
          labels: (
            (.labels // {})
            + if ((.projectId // "") != "") then {"field.cattle.io/projectId": (.projectId | split(":")[1])} else {} end
          )
        }
    )
  }'
}

# Run an API call as a different token without clobbering RANCHER_TOKEN.
with_token() {
  local token="$1"
  shift
  local saved="${RANCHER_TOKEN}" rc=0
  RANCHER_TOKEN="${token}"
  "$@" || rc=$?
  RANCHER_TOKEN="${saved}"
  return "${rc}"
}

# Norman project -> management.cattle.io/v3 Project JSON.
norman_project_to_k8s() {
  jq '{
    apiVersion: "management.cattle.io/v3",
    kind: "Project",
    metadata: (
      {
        name: (.id | split(":")[1]),
        namespace: .clusterId
      }
      + (if (.annotations // {}) != {} then {annotations: .annotations} else {} end)
      + (if (.labels // {}) != {} then {labels: .labels} else {} end)
    ),
    spec: (
      {
        clusterName: .clusterId,
        displayName: .name
      }
      + if ((.description // "") != "") then {description: .description} else {} end
    )
  }'
}

# Norman projectRoleTemplateBinding -> management.cattle.io/v3 PRTB JSON.
# $backing_ns is the project's backing namespace (PRTB metadata.namespace).
norman_prtb_to_k8s() {
  local backing_ns="$1"
  jq --arg ns "${backing_ns}" '{
    apiVersion: "management.cattle.io/v3",
    kind: "ProjectRoleTemplateBinding",
    metadata: (
      {
        name: (.name // (.id | split(":")[-1])),
        namespace: $ns
      }
      + (if (.labels // {}) != {} then {labels: .labels} else {} end)
    ),
    projectName: .projectId,
    roleTemplateName: .roleTemplateId
  }
  + (if (.userId // "") != "" then {userName: .userId} else {} end)
  + (if (.userPrincipalId // "") != "" then {userPrincipalName: .userPrincipalId} else {} end)
  + (if (.groupId // "") != "" then {groupName: .groupId} else {} end)
  + (if (.groupPrincipalId // "") != "" then {groupPrincipalName: .groupPrincipalId} else {} end)'
}

# Filesystem-safe token for directory and file names.
fs_safe() {
  local value="${1:-}"
  value="${value//\//-}"
  value="${value// /_}"
  value="$(printf '%s' "${value}" | tr -c 'A-Za-z0-9._-' '-')"
  value="$(printf '%s' "${value}" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "${value}" ]]; then
    value="unnamed"
  fi
  printf '%s' "${value}"
}

cluster_folder_name() {
  local display_name="$1"
  local cluster_id="$2"
  local safe_display
  safe_display="$(fs_safe "${display_name}")"
  printf '%s_%s' "${safe_display}" "${cluster_id}"
}

# Strip live-cluster and Steve-only fields so YAML is GitOps-ready.
# Reads YAML/JSON on stdin, writes sanitized YAML on stdout.
sanitize_yaml() {
  yq eval '
    del(
      .status,
      .id,
      .type,
      .links,
      .actions,
      .metadata.uid,
      .metadata.resourceVersion,
      .metadata.generation,
      .metadata.creationTimestamp,
      .metadata.managedFields,
      .metadata.deletionTimestamp,
      .metadata.deletionGracePeriodSeconds,
      .metadata.finalizers,
      .metadata.generateName,
      .metadata.ownerReferences,
      .metadata.fields,
      .metadata.relationships,
      .metadata.state
    )
    | del(.spec.finalizers)
    | .metadata.annotations |= ((. // {}) | with_entries(select(.key | test("^(lifecycle\\.cattle\\.io/|objectset\\.rio\\.cattle\\.io/|cattle\\.io/status|kubectl\\.kubernetes\\.io/last-applied-configuration|authz\\.management\\.cattle\\.io/creator-role-bindings)") | not)))
    | .metadata.labels |= ((. // {}) | with_entries(select(.key | test("crb-rb-labels-updated") | not)))
    | with(select(.metadata.annotations != null and ((.metadata.annotations | length) == 0)); del(.metadata.annotations))
    | with(select(.metadata.labels != null and ((.metadata.labels | length) == 0)); del(.metadata.labels))
  '
}

write_sanitized() {
  local dest="$1"
  mkdir -p "$(dirname "${dest}")"
  sanitize_yaml > "${dest}"
}

wait_for() {
  local description="$1"
  local timeout_s="$2"
  shift 2
  local elapsed=0
  while true; do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    if (( elapsed >= timeout_s )); then
      echo "error: timed out after ${timeout_s}s waiting for ${description}" >&2
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
}
