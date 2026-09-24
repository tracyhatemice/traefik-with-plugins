# Traefik with embedded plugins — design

Date: 2026-09-24
Status: approved 2026-09-24; revised after prototyping

## Goal

Publish `ghcr.io/tracyhatemice/traefik` (package name `traefik`, not the repo
name), a multi-arch (linux/amd64, linux/arm64) Traefik image with three
middlewares compiled into the binary instead of loaded through Yaegi, and keep
it current automatically as Traefik and the plugins release.

The approach follows
[david-garcia-garcia/traefik-with-plugins](https://github.com/david-garcia-garcia/traefik-with-plugins):
patch Traefik's plugin builder to consult an in-binary registry before Yaegi.

### Success criteria

1. A push to `main` produces a tested image for both architectures in GHCR.
2. A daily check detects a new upstream version (per each component's track
   policy), builds, tests, pushes, and commits the new pin to `versions.conf`
   with no human involvement.
3. A broken upstream release never replaces a working `:latest`.
4. Existing middleware configs written for the Yaegi plugins work unchanged
   (same plugin keys); only the `experimental.plugins` entries are removed.

## Components

| Component | Repo | Go module | Plugin key | Default track |
|---|---|---|---|---|
| Traefik | github.com/traefik/traefik | github.com/traefik/traefik/v3 | — | `stable-major` |
| ModSecurity | github.com/david-garcia-garcia/traefik-modsecurity | same as repo | `modsecurity` | `stable-major` |
| Robots.txt | github.com/solution-libre/traefik-plugin-robots-txt | same as repo | `robots-txt` | `stable-major` |
| Captcha Protect (fork) | github.com/tracyhatemice/captcha-protect | github.com/libops/captcha-protect | `captcha-protect` | `head` |

The captcha fork has no tags and its `go.mod` still declares
`github.com/libops/captcha-protect`, so it is pinned by commit SHA and wired in
with a `replace` directive.

Any tagged plugin can be switched to `head` by editing one line.

## `versions.conf`

A shell-sourceable file at the repo root, the single source of truth for what
goes into the image. Each component has three keys:

```
TRAEFIK_REPO=github.com/traefik/traefik
TRAEFIK_VERSION=v3.7.13
TRAEFIK_TRACK=stable-major

PLUGIN_CAPTCHA_PROTECT_REPO=github.com/tracyhatemice/captcha-protect
PLUGIN_CAPTCHA_PROTECT_VERSION=9cd7e2d<full 40-char sha>
PLUGIN_CAPTCHA_PROTECT_TRACK=head
```

Plugins are discovered by the `PLUGIN_<NAME>_REPO` naming convention; `<NAME>`
lowercased with `_`→`-` is the checkout directory name.

### Track policies

| Track | `VERSION` holds | Updater picks |
|---|---|---|
| `stable-major` | semver tag | newest non-prerelease tag with the same major as the current pin |
| `stable` | semver tag | newest non-prerelease tag, any major |
| `head` | 40-char commit SHA | current commit of the repo's default branch |
| `pinned` | tag or SHA | nothing; never changed automatically |

Rules:
- Never downgrade. A candidate replaces the current pin only if it is strictly
  newer by semver (a stable `v2.0.0` is newer than a pinned `v2.0.0-beta.1`).
- A hand-pinned prerelease under `stable-major` stays until a stable release of
  that major is newer.
- `stable-major` with a non-semver `VERSION` (e.g. after switching from `head`)
  behaves like `stable`, with a warning.
- Tags are read with `git ls-remote --tags`, so it works whether or not a repo
  publishes GitHub Releases.

## Build (`build/Dockerfile`)

Build context is the repo root (so the build can read `versions.conf`).

Stages:

1. **source** (`--platform=$BUILDPLATFORM`, `golang:1.26-alpine`,
   `GOTOOLCHAIN=auto`): shallow-fetch Traefik at `TRAEFIK_VERSION` (build arg).
2. **webui** (`--platform=$BUILDPLATFORM`, `node:24-alpine`, the Node major
   Traefik's own `webui/buildx.Dockerfile` uses): `yarn install --immutable &&
   yarn build`.
   Architecture-independent, so it runs once and is shared by both targets.
3. **builder** (from **source**):
   - copy the built webui into `webui/static` (needed by `go:embed`);
   - copy `versions.conf` and fail if its `TRAEFIK_VERSION` differs from the
     build arg;
   - `integrate-plugins.sh`: for every `PLUGIN_*` entry, shallow-fetch the repo
     at `VERSION` (tag or SHA), read its module path from its `go.mod`, then
     `go mod edit -require=<module>@v0.0.0-00010101000000-000000000000
     -replace=<module>=/plugins/<name>`. One path for tags, SHAs and forks.
     Fails if a plugin's module is not imported by `embedded-registry.go`
     (otherwise `go mod tidy` would silently drop it);
   - copy `embedded-registry.go` and its unit test into `pkg/plugins/`, apply
     `builder.patch`, `go mod tidy`, then run the registry unit tests
     (`go test ./pkg/plugins/ -run Embedded`) so a registry bug fails the build;
   - cross-compile: `CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build`
     with Traefik's version ldflags so `traefik version` and the dashboard show
     the real version instead of `dev`.
4. **runtime** (`alpine:3.24`, matching upstream Traefik's image):
   `ca-certificates tzdata` and the binary at `/traefik`. None of the three
   plugins reads files at runtime (captcha-protect falls back to its built-in
   challenge template when `challengeTmpl` does not exist). Same `ENTRYPOINT`,
   `EXPOSE`, `VOLUME` as upstream. OCI labels record every component's
   version.

Because Go and webui builds run on the build platform and cross-compile, no
QEMU emulation is needed for the heavy steps. QEMU is used only for the tiny
`apk add` in the arm64 runtime stage and the arm64 run check.

### Embedded registry (`build/embedded-registry.go`)

Adapted from the reference: a map of plugin key → `CreateConfig`/`New`
wrappers for the three plugins, mapstructure decoding identical to Yaegi's, and
per-plugin key remapping via `TRAEFIK_EMBEDDED_<KEY>_KEY` (key uppercased,
`-`→`_`, e.g. `TRAEFIK_EMBEDDED_CAPTCHA_PROTECT_KEY=captcha`). The reference
is MIT-licensed; its notice ships as `build/NOTICE`.

Unit tests (`build/embedded_registry_test.go`): default keys, env remapping,
string-valued config decoding into typed fields (labels deliver strings), and
the unknown-key error.

### Builder patch (`build/builder.patch`)

Same as the reference: at the top of `Builder.Build`, return
`BuildEmbeddedPlugin(...)` if the key is embedded. Applied with `patch`; a
rejected hunk fails the build.

The reference's `hub-removal.patch` is dropped: it no longer applies to
Traefik 3.7 (files moved), is purely cosmetic, and `api.disableDashboardAd`
already hides the upgrade button.

## Workflow (`.github/workflows/build.yml`)

Triggers:
- `push` to `main` (ignoring `**.md` and `docs/**`): build, test, push.
- `pull_request`: build both architectures and test; never push.
- `schedule` (daily): run the updater; if nothing changed, stop after ~1 min.
- `workflow_dispatch`: run the updater, then build and push even if nothing
  changed (e.g. to pick up base-image security fixes).

Two jobs, serialized per ref by a concurrency group (PR runs cancel older
ones; `main` runs queue):

**check** (~1 min):
1. Run the updater unit tests and shellcheck.
2. (schedule/dispatch) Run `scripts/update-versions.sh`: rewrites
   `versions.conf`, writes a change table to the job summary, sets
   `changed=true|false` and `changes`.
3. Decide `build`: false only for a scheduled run with no changes.
4. Upload `versions.conf` as an artifact for the build job.

**build** (only if `build`):
1. Checkout, overwrite `versions.conf` with the artifact; if it differs,
   commit locally as `github-actions[bot]` (not yet pushed).
2. Build `linux/amd64` with `load: true` → run the smoke test.
3. Build `linux/arm64` with `load: true` → `docker run --platform linux/arm64
   … version` under QEMU to prove the binary runs.
4. (main only) Log in to GHCR, build both platforms and push (layers cached
   from steps 2–3 and the GHA cache).
5. (main only, if bumped) Push the `versions.conf` commit to `main`.

Consequences:
- The commit is pushed only after the image is published, so `versions.conf`
  on `main` always describes `:latest`.
- If a new upstream version fails to build or test, the job fails (GitHub
  emails the failure), `:latest` is untouched, and the next daily run retries
  it. To stop retries, pin the component (`TRACK=pinned`) or fix the build.
- Commits pushed with `GITHUB_TOKEN` do not trigger another workflow run, so
  the bot commit does not cause a duplicate build.
- If step 5 fails (e.g. `main` moved), the next run finds the same updates and
  rebuilds idempotently.
- A `workflow_dispatch` on a branch other than `main` builds and tests only.

Permissions: `contents: write` (bot commit), `packages: write` (GHCR). Build
cache: `type=gha`.

### Image name and tags

Image: `ghcr.io/${{ github.repository_owner }}/traefik` (lowercased), i.e.
`ghcr.io/tracyhatemice/traefik`. The package name is set explicitly rather
than derived from the repo name. The `org.opencontainers.image.source` label
links the package to this repo, which is what lets this repo's `GITHUB_TOKEN`
push to it.

Tags:

- `latest`
- Traefik version, e.g. `v3.7.13` (moves when a plugin updates under the same
  Traefik version)
- `sha-<short commit>`: immutable; the commit whose `versions.conf` was built
  (for scheduled runs, the bot commit created in build step 1)

Plugin versions are recorded as OCI labels
(`io.github.tracyhatemice.traefik.plugin.<name>=<repo>@<version>`), Traefik's
as `org.opencontainers.image.version`, and all of them in the job summary.

## Smoke test (`test/smoke/`)

`docker compose` with the freshly built image plus `traefik/whoami`. The static
config has no `experimental.plugins`, so any working plugin must be embedded.
One router per plugin. Checks:

1. Each router is `enabled` in `/api/http/routers` (a plugin that fails to
   load shows `disabled` with `unknown plugin type`).
2. `robots-txt`: `GET /robots.txt` returns the configured custom rule.
3. `captcha-protect`: a request presenting a public client IP
   (`X-Forwarded-For: 203.0.113.7`; the plugin exempts private ranges, and
   Docker traffic arrives from a private bridge IP) is redirected `302` to
   `/challenge`.
4. `modsecurity`: its WAF URL points at a second Traefik entrypoint whose only
   router denies everything (`ipAllowList`), so a protected request returns
   `403`. (modsecurity fails open when the WAF is unreachable, so "enabled"
   alone would prove nothing. The WAF entrypoint is not a default entrypoint,
   otherwise the plugin's own WAF call would loop back through it.)
5. The dashboard is embedded (`GET /dashboard/` is `200`).
6. No `ERR`/`level=ERROR` lines in Traefik's log (`log.noColor: true`, so the
   match isn't broken by ANSI codes).

Run against the stock `traefik` image, checks 1–4 and 6 fail: the test
discriminates. On failure it prints Traefik's logs.

## Updater (`scripts/update-versions.sh`)

Bash, no dependencies beyond git. The pure logic (parse semver, filter by
track, compare, pick) is in functions sourced by
`scripts/update-versions.test.sh`, which feeds fixture tag lists covering:
same-major filtering, prerelease exclusion, never-downgrade, prerelease pin →
stable upgrade, `head` SHA change, `pinned` skip, non-semver under
`stable-major`. The network step (`git ls-remote`) is a thin wrapper. Network
or parse errors fail the run; nothing is partially written. Values are read
ignoring CRLF line endings (the repo is edited from WSL), and
`.gitattributes` forces LF in the repo.

## One-time setup (documented in README)

- The GHCR package inherits private visibility from this private repo. Pulling
  needs `docker login ghcr.io` with a PAT that has `read:packages`, or make the
  package public in its settings.
- If branch protection is later added to `main`, allow GitHub Actions to push,
  or the bot commit (step 6) fails.
- Remove `experimental.plugins` entries for these three plugins from Traefik's
  static config; keep middleware definitions as they are.

## Out of scope

- The reference's Pester/Cypress integration suites, CRS WAF stack, and
  benchmarks.
- GitHub Releases per build (job summary and labels cover version visibility).
- Docker Hub publishing.
- Auto-bumping the Go/Node/Alpine base image tags (floating minor tags such as
  `golang:1.26-alpine` pick up patch releases on each build; `GOTOOLCHAIN=auto`
  covers Traefik requiring a newer Go).

## Repository layout

```
versions.conf
build/Dockerfile
build/embedded-registry.go
build/embedded_registry_test.go
build/builder.patch
build/integrate-plugins.sh
build/NOTICE
scripts/update-versions.sh
scripts/update-versions.test.sh
test/smoke/compose.yaml
test/smoke/traefik.yml
test/smoke/dynamic.yml
test/smoke/run.sh
.github/workflows/build.yml
.dockerignore
.gitattributes
README.md
```
