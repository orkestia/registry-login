# Orkestia registry login

Log a GitHub Actions job into the Orkestia registry with **no stored secret**. The job proves who it is with the identity token GitHub issues to it, and gets a one-hour credential for your organization's namespace.

One step covers Docker images, Python packages (pip, uv, twine) and npm packages.

```yaml
permissions:
  id-token: write   # lets GitHub issue the job's identity token
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: orkestia/registry-login@v1
        id: orkestia
      - run: |
          docker build -t ${{ steps.orkestia.outputs.registry }}/api:${{ github.sha }} .
          docker push ${{ steps.orkestia.outputs.registry }}/api:${{ github.sha }}
```

The repository must belong to the GitHub organization connected to your Orkestia organization.

## What the step sets up

| Tool | After the step |
|---|---|
| Docker / buildx | `docker login registry.orkestia.dev` is done, with your namespace as the username |
| pip, uv | Requests to `packages.orkestia.dev` are authenticated for this job. Point them at your index: `pip install --extra-index-url "${{ steps.orkestia.outputs.pip-index-url }}" my-package` |
| twine, uv publish | Use the outputs: `twine upload --repository-url "${{ steps.orkestia.outputs.pip-upload-url }}" -u "$ORKESTIA_NAMESPACE" -p "$ORKESTIA_TOKEN" dist/*` |
| npm | Packages in the `@<namespace>` scope resolve from and publish to your namespace. Other packages still come from the public registry |

The credential is also exported to later steps as `ORKESTIA_TOKEN`, with the username in `ORKESTIA_NAMESPACE`. Nothing is written to your home directory except the Docker login. The pip and npm settings live in the job's temporary directory, which the runner empties after the job.

## Who can push

By default:

| Job | Access |
|---|---|
| Any repository of the connected GitHub organization, any event | pull / install |
| A push or a manual run on the repository's **default branch** | pull and push |
| A tag (`refs/tags/...`) or a job with a GitHub `environment:` | pull and push |
| `pull_request`, including from forks | pull only, always |

An organization admin can replace these defaults with your own rules (by repository, branch or tag, environment, event and workflow) in Orkestia. Ask for less access when a job only reads:

```yaml
      - uses: orkestia/registry-login@v1
        with:
          scope: pull
```

`scope: push` makes the step fail when the job may only pull, instead of failing later at the push.

## Inputs

| Input | Default | |
|---|---|---|
| `scope` | empty | `pull`, `push`, or empty for the widest access the job is allowed |
| `docker` | `true` | Run `docker login` when Docker is installed |
| `python` | `true` | Authenticate pip and uv to the package index for this job |
| `npm` | `true` | Map the `@<namespace>` scope to your npm registry for this job |
| `exchange-url` | Orkestia's | Leave the default |

## Outputs

| Output | Example |
|---|---|
| `namespace` | `acme` |
| `scope` | `push` |
| `registry` | `registry.orkestia.dev/acme` |
| `pip-index-url` | `https://packages.orkestia.dev/acme/simple/` |
| `pip-upload-url` | `https://packages.orkestia.dev/acme/` |
| `npm-registry` | `https://packages.orkestia.dev/acme/npm/` |

## Jobs longer than an hour

The credential is valid for one hour. Run the step again before a push that starts later than that, or use the Docker credential helper below, which fetches a fresh credential whenever Docker needs one.

## Docker credential helper

`docker-credential-orkestia` lets Docker fetch a credential by itself, with no login step. It needs `bash`, `curl` and `jq`, and a job with `permissions: id-token: write`.

```bash
sudo install -m 0755 docker-credential-orkestia /usr/local/bin/
sudo install -D -m 0644 lib.sh /usr/local/lib/orkestia/lib.sh
# ~/.docker/config.json
{ "credHelpers": { "registry.orkestia.dev": "orkestia" } }
```

Orkestia runner pools come with it installed.

## If the login is refused

The step prints the reason.

| Message | Fix |
|---|---|
| `this job cannot request a GitHub identity token` | Add `permissions: id-token: write` to the workflow or the job |
| `access_denied` | The repository is not in the connected GitHub organization, or no rule of your organization admits this job |
| `invalid_scope` | The job asked for `push` but may only pull (for example a pull request) |

## License

MIT
