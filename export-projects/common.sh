#!/usr/bin/env bash
# Shared helpers for Rancher project export.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${KUBECONFIG:=${REPO_ROOT}/local.yaml}"
: "${RANCHER_URL:=https://rancher-manager.somequant.club}"
: "${OUT_DIR:=${SCRIPT_DIR}/out}"

# Pull --kubeconfig / --rancher-url off the argument list. Remaining flags
# are left in CONNECTION_REST for the caller to parse.
parse_connection_flags() {
  CONNECTION_REST=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kubeconfig)
        if [[ $# -lt 2 ]]; then
          echo "error: $1 requires a path" >&2
          exit 1
        fi
        KUBECONFIG="$2"
        shift 2
        ;;
      --kubeconfig=*)
        KUBECONFIG="${1#*=}"
        shift
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
      *)
        CONNECTION_REST+=("$1")
        shift
        ;;
    esac
  done
}

resolve_connection() {
  if [[ -z "${KUBECONFIG:-}" ]]; then
    echo "error: kubeconfig is not set (use --kubeconfig or KUBECONFIG)" >&2
    exit 1
  fi
  if [[ ! -f "${KUBECONFIG}" ]]; then
    echo "error: kubeconfig not found: ${KUBECONFIG}" >&2
    exit 1
  fi
  KUBECONFIG="$(cd "$(dirname "${KUBECONFIG}")" && pwd)/$(basename "${KUBECONFIG}")"
  RANCHER_URL="${RANCHER_URL%/}"
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

kctl() {
  kubectl --kubeconfig "${KUBECONFIG}" "$@"
}

rancher_api() {
  local method="$1"
  local path="$2"
  shift 2
  if [[ -z "${RANCHER_TOKEN:-}" ]]; then
    echo "error: RANCHER_TOKEN is not set" >&2
    exit 1
  fi
  curl -sS --fail ${CURL_INSECURE:+-k} \
    -X "${method}" \
    -H "Authorization: Bearer ${RANCHER_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@" \
    "${RANCHER_URL%/}${path}"
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

# Strip live-cluster runtime fields so YAML is GitOps-ready.
# Reads YAML on stdin, writes sanitized YAML on stdout.
sanitize_yaml() {
  yq eval '
    del(
      .status,
      .metadata.uid,
      .metadata.resourceVersion,
      .metadata.generation,
      .metadata.creationTimestamp,
      .metadata.managedFields,
      .metadata.deletionTimestamp,
      .metadata.deletionGracePeriodSeconds,
      .metadata.finalizers,
      .metadata.generateName,
      .metadata.ownerReferences
    )
    | .metadata.annotations |= ((. // {}) | with_entries(select(.key | test("^(lifecycle\\.cattle\\.io/|objectset\\.rio\\.cattle\\.io/|kubectl\\.kubernetes\\.io/last-applied-configuration|authz\\.management\\.cattle\\.io/creator-role-bindings)") | not)))
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

cluster_display_name() {
  local cluster_id="$1"
  local display
  display="$(kctl get clusters.management.cattle.io "${cluster_id}" -o jsonpath='{.spec.displayName}' 2>/dev/null || true)"
  if [[ -z "${display}" ]]; then
    display="${cluster_id}"
  fi
  printf '%s' "${display}"
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
