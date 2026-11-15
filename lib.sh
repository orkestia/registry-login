# Shared by login.sh and docker-credential-orkestia. Sourced, not run.
# shellcheck shell=bash
# The constants are read by the scripts that source this file.
# shellcheck disable=SC2034

ORKESTIA_AUDIENCE="registry.orkestia.dev"
ORKESTIA_REGISTRY_HOST="registry.orkestia.dev"
ORKESTIA_PACKAGES_HOST="packages.orkestia.dev"
ORKESTIA_EXCHANGE_URL_DEFAULT="https://workflow-api.orkestia.dev/api/auth/workload/token"

orkestia_need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "orkestia: '$tool' is required on the runner" >&2; return 1; }
  done
}

# orkestia_exchange <scope or empty> <exchange url>
# Prints the exchange response (JSON with access_token, scope, namespace) on success.
# On refusal prints the reason to stderr and returns 1. Never prints a token on failure.
orkestia_exchange() {
  local scope="$1" url="${2:-$ORKESTIA_EXCHANGE_URL_DEFAULT}" oidc resp err
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    echo "orkestia: this job cannot request a GitHub identity token. Add 'permissions: id-token: write' to the workflow or the job." >&2
    return 1
  fi
  oidc=$(curl -fsS --retry 2 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$ORKESTIA_AUDIENCE" | jq -r '.value // empty') || oidc=""
  if [ -z "$oidc" ]; then
    echo "orkestia: GitHub did not issue an identity token for this job." >&2
    return 1
  fi
  local args=(
    -sS --retry 2 "$url"
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange
    -d subject_token_type=urn:ietf:params:oauth:token-type:jwt
    -d "audience=$ORKESTIA_AUDIENCE"
    --data-urlencode "subject_token=$oidc"
  )
  [ -n "$scope" ] && args+=(-d "scope=$scope")
  resp=$(curl "${args[@]}") || { echo "orkestia: the login service could not be reached." >&2; return 1; }
  if [ -z "$(jq -r '.access_token // empty' <<<"$resp" 2>/dev/null)" ]; then
    err=$(jq -r '"\(.error // "unknown_error"): \(.error_description // "no description")"' <<<"$resp" 2>/dev/null) \
      || err="unexpected response from the login service"
    echo "orkestia: login refused ($err)" >&2
    return 1
  fi
  # Refuse anything that is not a plain JWT, namespace and scope: they end up in env files.
  if ! jq -e '(.access_token | test("\\A[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\z"))
      and (.namespace | type == "string" and test("\\A[a-z0-9][a-z0-9-]{0,62}\\z"))
      and (.scope == "pull" or .scope == "push")' <<<"$resp" >/dev/null 2>&1; then
    echo "orkestia: unexpected response from the login service" >&2
    return 1
  fi
  printf '%s' "$resp"
}
