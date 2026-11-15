#!/usr/bin/env bash
# Composite action body. Inputs arrive as INPUT_* environment variables.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"

orkestia_need curl jq

scope="${INPUT_SCOPE:-}"
case "$scope" in
  "" | pull | push) ;;
  *) echo "::error::scope must be 'pull', 'push' or empty, got '$scope'"; exit 1 ;;
esac

if ! resp=$(orkestia_exchange "$scope" "${INPUT_EXCHANGE_URL:-}"); then
  echo "::error::Orkestia registry login refused. See the message above."
  exit 1
fi

token=$(jq -r .access_token <<<"$resp")
echo "::add-mask::$token"
namespace=$(jq -r .namespace <<<"$resp")
granted=$(jq -r .scope <<<"$resp")
case "$namespace" in
  "" | *[!a-z0-9-]*) echo "::error::unexpected namespace in the login response"; exit 1 ;;
esac

pip_index="https://$ORKESTIA_PACKAGES_HOST/$namespace/simple/"
pip_upload="https://$ORKESTIA_PACKAGES_HOST/$namespace/"
npm_registry="https://$ORKESTIA_PACKAGES_HOST/$namespace/npm/"

{
  echo "ORKESTIA_TOKEN=$token"
  echo "ORKESTIA_NAMESPACE=$namespace"
} >>"$GITHUB_ENV"

{
  echo "namespace=$namespace"
  echo "scope=$granted"
  echo "registry=$ORKESTIA_REGISTRY_HOST/$namespace"
  echo "pip-index-url=$pip_index"
  echo "pip-upload-url=$pip_upload"
  echo "npm-registry=$npm_registry"
} >>"$GITHUB_OUTPUT"

work="${RUNNER_TEMP:?RUNNER_TEMP is not set}/orkestia-registry-login"
mkdir -p "$work"
chmod 700 "$work"

if [ "${INPUT_DOCKER:-true}" = "true" ]; then
  if command -v docker >/dev/null 2>&1; then
    printf '%s' "$token" | docker login "$ORKESTIA_REGISTRY_HOST" -u "$namespace" --password-stdin >/dev/null
    echo "docker: logged in to $ORKESTIA_REGISTRY_HOST"
  else
    echo "docker: not installed, skipped"
  fi
fi

if [ "${INPUT_PYTHON:-true}" = "true" ]; then
  # A netrc for this job only (RUNNER_TEMP is emptied after the job). Keep any existing entries.
  netrc="$work/netrc"
  : >"$netrc"
  chmod 600 "$netrc"
  existing="${NETRC:-$HOME/.netrc}"
  if [ -f "$existing" ] && [ "$existing" != "$netrc" ]; then
    grep -v "^machine $ORKESTIA_PACKAGES_HOST " "$existing" >>"$netrc" || true
  fi
  printf 'machine %s login %s password %s\n' "$ORKESTIA_PACKAGES_HOST" "$namespace" "$token" >>"$netrc"
  echo "NETRC=$netrc" >>"$GITHUB_ENV"
  echo "python: pip and uv authenticate to $ORKESTIA_PACKAGES_HOST (index $pip_index)"
fi

if [ "${INPUT_NPM:-true}" = "true" ]; then
  # Reuse the user npmrc that actions/setup-node created, otherwise make one for this job.
  npmrc="${NPM_CONFIG_USERCONFIG:-}"
  if [ -z "$npmrc" ]; then
    npmrc="$work/npmrc"
    if [ -f "$HOME/.npmrc" ]; then cp "$HOME/.npmrc" "$npmrc"; else : >"$npmrc"; fi
    echo "NPM_CONFIG_USERCONFIG=$npmrc" >>"$GITHUB_ENV"
  fi
  host_path="//$ORKESTIA_PACKAGES_HOST/$namespace/npm/"
  if [ -f "$npmrc" ]; then
    tmp=$(mktemp "$work/npmrc.XXXXXX")
    grep -v -e "^@$namespace:registry=" -e "^$host_path:_authToken=" "$npmrc" >"$tmp" || true
    cat "$tmp" >"$npmrc"
    rm -f "$tmp"
  fi
  # The token is read from the environment when npm runs; it is not written to the file.
  # shellcheck disable=SC2016
  printf '@%s:registry=%s\n%s:_authToken=${ORKESTIA_TOKEN}\n' "$namespace" "$npm_registry" "$host_path" >>"$npmrc"
  echo "npm: @$namespace packages resolve from $npm_registry"
fi

echo "Orkestia registry: namespace '$namespace', access '$granted', valid for 1 hour."
