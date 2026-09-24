# traefik with embedded plugins

Traefik with three middleware plugins compiled into the binary instead of
loaded through Yaegi, rebuilt automatically when Traefik or a plugin releases.

```
ghcr.io/tracyhatemice/traefik    linux/amd64, linux/arm64
```

| Plugin key | Source | Follows |
|---|---|---|
| `modsecurity` | [david-garcia-garcia/traefik-modsecurity](https://github.com/david-garcia-garcia/traefik-modsecurity) | stable releases, same major |
| `robots-txt` | [solution-libre/traefik-plugin-robots-txt](https://github.com/solution-libre/traefik-plugin-robots-txt) | stable releases, same major |
| `captcha-protect` | [tracyhatemice/captcha-protect](https://github.com/tracyhatemice/captcha-protect) (fork of libops/captcha-protect) | every commit on `main` |

Traefik itself follows stable v3 releases. The exact versions in an image are
in [`versions.conf`](versions.conf) at the commit it was built from, in the
image labels (`docker inspect`), and in the workflow run summary.

## Tags

- `latest`
- the Traefik version, e.g. `v3.7.13`. Moves when a plugin updates under the
  same Traefik release.
- `sha-<commit>`, one per commit of this repository. A manual rebuild of the
  same commit republishes it with refreshed base layers, so pin the image
  digest when you need a byte-for-byte fixed image.

## Using it

Remove the `experimental.plugins` entries for these plugins from Traefik's
static configuration. Middleware definitions stay the same:

```yaml
http:
  middlewares:
    waf:
      plugin:
        modsecurity:
          modSecurityUrl: http://waf:8080
    robots:
      plugin:
        robots-txt:
          aiRobotsTxt: true
    captcha:
      plugin:
        captcha-protect:
          protectRoutes: /
          captchaProvider: turnstile
          siteKey: <site key>
          secretKey: <secret key>
```

or as labels, e.g.
`traefik.http.middlewares.captcha.plugin.captcha-protect.protectRoutes=/`.

captcha-protect never challenges private addresses (127/8, 10/8, 172.16/12,
192.168/16, fc00::/8). If Traefik sits behind another proxy or load balancer,
set `ipForwardedHeader` (and `ipDepth`) so it sees the real client IP.

To use a different plugin key, set `TRAEFIK_EMBEDDED_<KEY>_KEY` on the
container, with the default key uppercased and `-` replaced by `_`:

```yaml
environment:
  TRAEFIK_EMBEDDED_CAPTCHA_PROTECT_KEY: captcha # plugin.captcha instead of plugin.captcha-protect
```

## How updates work

[`versions.conf`](versions.conf) pins every component. Each has a `_TRACK`:

| Track | Follows |
|---|---|
| `stable-major` | newest stable tag with the same major version as the pin |
| `stable` | newest stable tag, any major |
| `head` | latest commit on the default branch (the pin is a commit SHA) |
| `pinned` | nothing; never changed automatically |

Every day at 04:23 UTC the [build workflow](.github/workflows/build.yml) checks
upstream. If anything moved, it builds both architectures, runs the smoke test,
pushes the image, and only then commits the new `versions.conf` to `main`. If
the new version fails to build or test, the run fails, `latest` stays as it
was, and the next day's run tries again. To stop the retries, set that
component's track to `pinned` or fix the build.

Every push to `main` is built, tested and published too, and it checks
upstream first in the same way, so a push never publishes older versions than
the daily check would. If someone pushes while a run is building, that run
leaves the version bump to the run queued for the newer commit.

Upgrades across a major version (Traefik v4, a plugin's v2) are deliberate:
edit the version in `versions.conf` and push. To hold a component at a
specific version, including an older one, set its track to `pinned`.

To rebuild on demand, run the workflow from the Actions tab or with
`gh workflow run build.yml`. A manual rebuild uses the current `alpine:3.24`
base image and reinstalls the Alpine packages on top of it
(`ca-certificates`, `tzdata`), so it picks up Alpine security fixes.

## Adding a plugin

1. Add `PLUGIN_<NAME>_REPO`, `_VERSION` and `_TRACK` to `versions.conf`.
2. Register it in [`build/embedded-registry.go`](build/embedded-registry.go):
   import its Go module and add a `basePluginRegistry` entry. The build fails
   if a plugin in `versions.conf` is not imported there. Add its key to
   `TestEmbeddedRegistryDefaultKeys` in `build/embedded_registry_test.go`.
3. Add a router and a check for it to [`test/smoke/`](test/smoke/).

## Building and testing locally

```sh
eval "$(tr -d '\r' < versions.conf)" # tolerate Windows line endings
docker buildx build -f build/Dockerfile \
  --build-arg TRAEFIK_REPO="$TRAEFIK_REPO" --build-arg TRAEFIK_VERSION="$TRAEFIK_VERSION" \
  -t traefik-local --load .
IMAGE=traefik-local test/smoke/run.sh
scripts/update-versions.test.sh
scripts/push-version-bump.test.sh
build/integrate-plugins.test.sh
```

## Repository settings

- The workflow creates the `traefik` package on its first push. If a package
  with that name already exists under the account and isn't linked to this
  repository, give this repository write access under the package's "Manage
  Actions access" settings.
- If branch protection is added to `main`, allow GitHub Actions to push, or the
  daily version bump commit fails.
- Optional: add `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a read-only access
  token) as repository secrets, and the workflow logs in to Docker Hub so base
  image pulls don't hit the anonymous rate limit.

## Licenses and credits

The image ships the license of Traefik and of each embedded plugin under
`/licenses/<component>/`, plus [`build/NOTICE`](build/NOTICE) as
`/licenses/NOTICE`:

```sh
docker run --rm --entrypoint find ghcr.io/tracyhatemice/traefik /licenses -type f
```

The embedded-plugin approach, registry and builder patch are adapted from
[david-garcia-garcia/traefik-with-plugins](https://github.com/david-garcia-garcia/traefik-with-plugins)
(MIT, see [`build/NOTICE`](build/NOTICE)).
