#!/usr/bin/env bash
# Shared helpers for Rancher project export (Rancher HTTP API only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${RANCHER_URL:=https://rancher-manager.somequant.club}"
: "${OUT_DIR:=${SCRIPT_DIR}/out}"

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

# List a Steve collection, following pagination.next. Prints {items:[...]}.
steve_list() {
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
