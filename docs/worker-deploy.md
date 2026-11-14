# Deploy a Worker through one shared path

Automatic deploys on `main`, manual Actions runs, and a maintainer machine
should not run three different deploy procedures. This kit ships one script that
runs the preflight, calls wrangler, and records the deployed version id. A
reusable workflow calls the same script from GitHub Actions.

## What the shared path runs

[`../scripts/worker-deploy.sh`](../scripts/worker-deploy.sh) accepts a Worker
directory and one mode:

| Mode | Steps |
| --- | --- |
| `preflight` (default) | `npm ci`, typecheck, tests, `npx --no-install wrangler deploy --dry-run` |
| `deploy` | the same preflight, then `npx --no-install wrangler deploy` |

Every preflight step is fail-closed. A non-zero exit stops the run, and the
deploy never starts after a failed step. The script prints one progress line per
step on stderr.

- Typecheck runs `npm run typecheck` when `package.json` defines that script. It
  falls back to `npx --no-install tsc --noEmit` when `tsconfig.json` exists, and
  otherwise skips with a note.
- Tests run `npm test` when `package.json` defines that script. `--skip-tests`
  skips the step and is discouraged.
- The dry run always runs. It catches a broken wrangler config before a deploy.

On a successful deploy the script prints one stdout line, `version_id=<id>`. It
also appends that line to `GITHUB_OUTPUT` when that path is a writable regular
file. Child tool output goes to stderr after redaction. If wrangler exits 0 but
the output has no valid `Version ID`, the script fails closed.

Exit codes:

| Code | Meaning |
| --- | --- |
| 0 | Okay |
| 1 | Preflight, deploy, smoke, or rate-limit hook failure |
| 2 | Usage error |
| 3 | A required command is missing (`npm`, `npx`, `node`, or `curl` when a smoke or hook is requested) |

## Call the reusable workflow

[`../.github/workflows/workers-deploy.yml`](../.github/workflows/workers-deploy.yml)
is callable only through `workflow_call`, so this public repository never gains
a deploy workflow of its own. A consuming repository adds a thin workflow:

```yaml
name: Deploy worker

on:
  push:
    branches:
      - main
    paths:
      - "worker/**"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  deploy:
    uses: yohei1126/agent-ops-kit/.github/workflows/workers-deploy.yml@<kit-commit-sha>
    with:
      working-directory: worker
      environment: production
      smoke: true
      smoke-url: https://<worker-host>
      smoke-path: /health
    secrets:
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

Replace `<kit-commit-sha>` with a full commit SHA of this repository. Pinning to
a full SHA keeps the workflow and the script it checks out on the same commit,
and it keeps a moving branch from changing what a consumer runs.

The workflow checks out the caller repository, then checks this kit at the
workflow's own commit into `.agent-ops-kit`. Node comes from the caller's
`.nvmrc` through `node-version-file`, never a hard-coded version. The first
preflight step runs without secrets, so a broken Worker fails before the deploy
step. Deploy mode repeats the full preflight inside the shared script, so
automatic and manual runs share one code path. During that repeated preflight
the script withholds `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` from
`npm ci`, typecheck, tests, and the wrangler dry run, and exposes them only
to the real `wrangler deploy`.

Inputs:

| Input | Default | Purpose |
| --- | --- | --- |
| `working-directory` | `.` | Worker directory with `package.json` and the wrangler config |
| `environment` | empty | GitHub environment for the job, so a consumer can require reviewers |
| `smoke` | `false` | Run the post-deploy smoke `GET` |
| `smoke-url` | empty | Smoke base URL, `https://` outside local tests |
| `smoke-path` | `/health` | Smoke request path |
| `rate-limit-check` | `false` | Run the post-deploy rate-limit hook |
| `rate-limit-path` | `/health` | Hook request path |
| `rate-limit-limit` | empty | Documented limit per window |
| `rate-limit-window` | empty | Documented window in seconds |
| `rate-limit-requests` | empty | Sequential requests, default `limit + 1` |
| `rate-limit-mode` | `enforce` | `enforce` or `detect` |
| `skip-tests` | `false` | Skip the test step (discouraged) |

The job exposes one output, `version-id`, taken from the script's
`GITHUB_OUTPUT` line.

## Run the same path locally

Run the preflight first, then deploy with the same binary and lockfile:

```bash
scripts/worker-deploy.sh --dir <worker-dir> --mode preflight
scripts/worker-deploy.sh --dir <worker-dir> --mode deploy
```

The local run uses the consumer's `node_modules` and lockfile, so
`npm ci` and the wrangler version match CI. Authenticate with the maintainer's
`wrangler login`, or export `CLOUDFLARE_API_TOKEN` in the shell before a deploy.
Never place a token value in a command argument, a file, or a log.

## Token and environment setup

Create a scoped Cloudflare API token with Workers Scripts edit and account read
only. Store it as a GitHub environment secret named `CLOUDFLARE_API_TOKEN`, and
store the account id as `CLOUDFLARE_ACCOUNT_ID`. The reusable workflow declares
both as required secrets and maps them only through the deploy step's `env:`.

Environment protection (required reviewers, deployment branches) stays with the
consumer's maintainer. An `environment` input that names a protected environment
makes the deploy job wait for approval. The kit never creates or rotates a token,
and it only forwards the values the workflow passes.

## Smoke and rate-limit hook

Both run only in deploy mode, only after a successful deploy, and only when
requested.

- `--smoke-url` enables a `GET` on `<url><smoke-path>`. The URL must be
  `https://`; `http://127.0.0.1` and `http://localhost` are allowed for tests.
  The check requires a 2xx and retries three times.
- `--rate-limit-check` runs the sibling
  [`../scripts/rate-limit-check.sh`](../scripts/rate-limit-check.sh) with
  `--base-url` set to the smoke URL, plus `--rl-limit`, `--rl-window`, and
  optional `--rl-path`, `--rl-requests`, and `--rl-mode`.

The rate-limit hook is off by default because it returns 429 by design and
consumes the limit window. It also needs a request burst that fits inside the
window, so run it when the route can absorb the traffic. Enabling the hook
requires the smoke base URL, so the smoke `GET` runs as well.

A smoke or hook failure exits 1. The version id is printed first and the message
says the deploy itself succeeded, so the maintainer can roll back.

## Concurrency

The deploy job uses the group
`workers-deploy-<repository>-<environment-or-working-directory>` with
`cancel-in-progress: false`. Overlapping `main` pushes and manual runs queue
instead of interleaving, and a new run never cancels a running deploy.

## Rollback

Wrangler keeps prior versions. Find an id, then restore it:

```bash
npx --no-install wrangler deployments list
npx --no-install wrangler versions list
npx --no-install wrangler rollback [<version-id>]
```

Run these in the Worker directory with the same token. Automatic rollback is out
of scope for this kit. A failed smoke or hook check leaves the deploy in place
and reports the version id, and the maintainer decides whether to roll back.

## Relation to the deploy-hash helper

[`lib/deploy-hash.sh`](lib/deploy-hash.sh) is unchanged. It waits for a served
asset or ETag to change and never deploys. The deploy script may compose with it
later, for example to wait for the new bundle before a smoke check, but the two
helpers stay separate today.

## Safety properties

- Shell xtrace (`set -x` or `bash -x`) is refused with exit 2, because xtrace
  prints expanded values.
- Values of `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, and any environment
  variable whose name matches `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*_KEY`, or
  `*API_KEY*` are replaced with `[REDACTED]` before output is printed. Values
  shorter than six characters are not used as patterns.
- Secrets are never passed as command arguments and never echoed.
- Child output is captured in mode 600 files inside a `mktemp` directory that a
  trap removes. The wrangler capture file is the only unredacted disk copy.
- Smoke and hook requests use `curl --fail --silent --show-error --max-time 10
  --proto =https,http` with no redirects, credentials, cookies, or auth headers.
- The reusable workflow keeps secrets in the deploy step's `env:` only, pins
  every action to a full commit SHA, and sets `contents: read`.
- In deploy mode, preflight children (`npm ci`, typecheck, tests, and the
  wrangler dry run) run without `CLOUDFLARE_API_TOKEN` or
  `CLOUDFLARE_ACCOUNT_ID` in their environment. Only the real `wrangler deploy`
  sees those values. This is enforced by
  [`../scripts/tests/test_worker_deploy.sh`](../scripts/tests/test_worker_deploy.sh).

## Related

- [`../scripts/README.md`](../scripts/README.md#deploy-a-worker-through-one-shared-script)
- [`dev-loop-rules.md`](dev-loop-rules.md)
- [`../templates/dev-loop/GATES.md`](../templates/dev-loop/GATES.md#deploy-hash)
- [`../templates/workers-do-rate-limiter/README.md`](../templates/workers-do-rate-limiter/README.md)
