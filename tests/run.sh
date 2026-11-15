#!/usr/bin/env bash
# Offline tests: fake curl and docker on PATH, no network.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fails=0

mkdir -p "$scratch/bin"
cat >"$scratch/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl. Records every call; answers the identity request and the exchange.
echo "$*" >>"$FAKE_LOG"
case "$*" in
  *audience=registry.orkestia.dev*Authorization*|*Authorization*audience=registry.orkestia.dev*)
    echo '{"value":"github-oidc-jwt"}' ;;
  *token-exchange*)
    case "$FAKE_EXCHANGE" in
      grant) printf '{"access_token":"orkestia.secret.token","scope":"%s","namespace":"acme","token_type":"Bearer","expires_in":3600}' "${FAKE_SCOPE:-push}" ;;
      deny) echo '{"error":"access_denied","error_description":"no trust rule admits this job"}' ;;
      bad-ns) echo '{"access_token":"a.b.c","scope":"pull","namespace":"../x"}' ;;
      bad-token) printf '{"access_token":"a.b.c\\nEVIL=1","scope":"pull","namespace":"acme"}' ;;
      bad-scope) echo '{"access_token":"a.b.c","scope":"admin","namespace":"acme"}' ;;
      down) exit 7 ;;
    esac ;;
  *) echo "unexpected curl call: $*" >&2; exit 99 ;;
esac
EOF
cat >"$scratch/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $* password=$(cat)" >>"$FAKE_DOCKER_LOG"
EOF
chmod +x "$scratch/bin/curl" "$scratch/bin/docker"

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

new_job() {
  job="$scratch/job-$1"
  rm -rf "$job"
  mkdir -p "$job/temp" "$job/home"
  : >"$job/env"; : >"$job/out"; : >"$job/curl.log"; : >"$job/docker.log"
}

run_login() {
  env -i PATH="$scratch/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" HOME="$job/home" \
    RUNNER_TEMP="$job/temp" GITHUB_ENV="$job/env" GITHUB_OUTPUT="$job/out" \
    FAKE_LOG="$job/curl.log" FAKE_DOCKER_LOG="$job/docker.log" "$@" \
    bash "$root/login.sh" >"$job/stdout" 2>"$job/stderr"
}

ids=(ACTIONS_ID_TOKEN_REQUEST_URL="https://gh.example/token?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req)

# 1. Granted: docker, netrc, npmrc, env and outputs.
new_job grant
printf '//npm.pkg.github.com/:_authToken=keep\n' >"$job/home/.npmrc"
printf 'machine example.com login a password b\n' >"$job/home/.netrc"
if run_login "${ids[@]}" FAKE_EXCHANGE=grant; then ok "login succeeds"; else bad "login succeeds: $(cat "$job/stderr")"; fi
check "token masked" "grep -q '::add-mask::orkestia.secret.token' '$job/stdout'"
check "token printed only in the mask line" "[ \"\$(grep -c orkestia.secret.token '$job/stdout')\" = 1 ]"
check "docker login as the namespace" "grep -q 'docker login registry.orkestia.dev -u acme --password-stdin password=orkestia.secret.token' '$job/docker.log'"
check "outputs" "grep -qx 'namespace=acme' '$job/out' && grep -qx 'scope=push' '$job/out' && grep -qx 'registry=registry.orkestia.dev/acme' '$job/out' && grep -qx 'pip-index-url=https://packages.orkestia.dev/acme/simple/' '$job/out' && grep -qx 'npm-registry=https://packages.orkestia.dev/acme/npm/' '$job/out'"
check "env token" "grep -qx 'ORKESTIA_TOKEN=orkestia.secret.token' '$job/env'"
check "netrc in RUNNER_TEMP keeps old entries" "grep -qx 'NETRC=$job/temp/orkestia-registry-login/netrc' '$job/env' && grep -q 'machine example.com' '$job/temp/orkestia-registry-login/netrc' && grep -q 'machine packages.orkestia.dev login acme password orkestia.secret.token' '$job/temp/orkestia-registry-login/netrc'"
check "netrc is 600" "[ \"\$(stat -c %a '$job/temp/orkestia-registry-login/netrc' 2>/dev/null || stat -f %Lp '$job/temp/orkestia-registry-login/netrc')\" = 600 ]"
npmrc="$job/temp/orkestia-registry-login/npmrc"
check "npmrc keeps old lines, adds scope" "grep -q npm.pkg.github.com '$npmrc' && grep -qx '@acme:registry=https://packages.orkestia.dev/acme/npm/' '$npmrc'"
check "npmrc references the env, not the token" "grep -qxF '//packages.orkestia.dev/acme/npm/:_authToken=\${ORKESTIA_TOKEN}' '$npmrc' && ! grep -q orkestia.secret.token '$npmrc'"
check "home files untouched" "! grep -q orkestia '$job/home/.npmrc' && ! grep -q orkestia '$job/home/.netrc'"
check "no scope sent by default" "! grep -q 'scope=' '$job/curl.log'"

# 2. Running twice does not duplicate npm lines (setup-node style NPM_CONFIG_USERCONFIG).
new_job twice
user="$job/temp/setup-node.npmrc"; : >"$user"
run_login "${ids[@]}" FAKE_EXCHANGE=grant NPM_CONFIG_USERCONFIG="$user" || true
run_login "${ids[@]}" FAKE_EXCHANGE=grant NPM_CONFIG_USERCONFIG="$user" || true
check "setup-node npmrc reused, no duplicates" "[ \"\$(grep -c '^@acme:registry=' '$user')\" = 1 ] && ! grep -q NPM_CONFIG_USERCONFIG '$job/env'"

# 3. Explicit scope is sent; a bad scope is refused before any call.
new_job scope
run_login "${ids[@]}" FAKE_EXCHANGE=grant FAKE_SCOPE=pull INPUT_SCOPE=pull || true
check "scope=pull sent" "grep -q 'scope=pull' '$job/curl.log'"
new_job badscope
if run_login "${ids[@]}" FAKE_EXCHANGE=grant INPUT_SCOPE=admin; then bad "bad scope refused"; else ok "bad scope refused"; fi
check "no call for a bad scope" "[ ! -s '$job/curl.log' ]"

# 4. Refusals.
new_job deny
if run_login "${ids[@]}" FAKE_EXCHANGE=deny; then bad "denied exchange fails"; else ok "denied exchange fails"; fi
check "reason shown" "grep -q 'access_denied: no trust rule admits this job' '$job/stderr'"
check "nothing exported on refusal" "[ ! -s '$job/env' ] && [ ! -s '$job/docker.log' ]"
new_job noperm
if run_login FAKE_EXCHANGE=grant; then bad "no id-token permission fails"; else ok "no id-token permission fails"; fi
check "permission hint" "grep -q 'id-token: write' '$job/stderr'"
new_job down
if run_login "${ids[@]}" FAKE_EXCHANGE=down; then bad "unreachable service fails"; else ok "unreachable service fails"; fi
new_job badns
if run_login "${ids[@]}" FAKE_EXCHANGE=bad-ns; then bad "odd namespace refused"; else ok "odd namespace refused"; fi
new_job badtoken
if run_login "${ids[@]}" FAKE_EXCHANGE=bad-token; then bad "token with a newline refused"; else ok "token with a newline refused"; fi
check "nothing exported for a bad token" "[ ! -s '$job/env' ]"
new_job badgrant
if run_login "${ids[@]}" FAKE_EXCHANGE=bad-scope; then bad "unknown granted scope refused"; else ok "unknown granted scope refused"; fi

# 5. Opt-outs.
new_job optout
run_login "${ids[@]}" FAKE_EXCHANGE=grant INPUT_DOCKER=false INPUT_PYTHON=false INPUT_NPM=false || true
check "opt-outs skip docker, netrc and npmrc" "[ ! -s '$job/docker.log' ] && ! grep -q NETRC '$job/env' && ! grep -q NPM_CONFIG '$job/env'"

# 6. Credential helper.
helper() {
  env -i PATH="$scratch/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" HOME="$job/home" \
    RUNNER_TEMP="$job/temp" FAKE_LOG="$job/curl.log" "$@"
}
new_job helper
out=$(printf 'https://registry.orkestia.dev' | helper "${ids[@]}" FAKE_EXCHANGE=grant "$root/docker-credential-orkestia" get) || out=""
check "helper get returns the namespace and token" "[ \"\$(jq -r .Username <<<'$out')\" = acme ] && [ \"\$(jq -r .Secret <<<'$out')\" = orkestia.secret.token ] && [ \"\$(jq -r .ServerURL <<<'$out')\" = registry.orkestia.dev ]"
printf 'registry.orkestia.dev' | helper "${ids[@]}" FAKE_EXCHANGE=deny "$root/docker-credential-orkestia" get >/dev/null 2>&1 || true
check "helper reuses its token within the job" "[ \"\$(grep -c token-exchange '$job/curl.log')\" = 1 ]"
check "helper cache is private" "[ \"\$(stat -c %a '$job/temp/orkestia-registry-login' 2>/dev/null || stat -f %Lp '$job/temp/orkestia-registry-login')\" = 700 ]"
new_job helper-other
if out=$(printf 'ghcr.io' | helper "${ids[@]}" FAKE_EXCHANGE=grant "$root/docker-credential-orkestia" get); then bad "other registry not served"; else ok "other registry not served"; fi
check "not-found text for other registries" "[ '$out' = 'credentials not found in native keychain' ] && [ ! -s '$job/curl.log' ]"
new_job helper-deny
if printf 'registry.orkestia.dev' | helper "${ids[@]}" FAKE_EXCHANGE=deny "$root/docker-credential-orkestia" get >/dev/null 2>&1; then bad "helper refusal is not-found"; else ok "helper refusal is not-found"; fi
check "helper list/store/erase" "[ \"\$(helper '$root/docker-credential-orkestia' list)\" = '{}' ] && echo '{}' | helper '$root/docker-credential-orkestia' store && echo x | helper '$root/docker-credential-orkestia' erase"

echo
if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
