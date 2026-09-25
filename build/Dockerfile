# syntax=docker/dockerfile:1

# Traefik with plugins compiled into the binary.
#
# Build from the repo root; TRAEFIK_REPO and TRAEFIK_VERSION must match
# versions.conf (checked below). They are build args rather than read from
# versions.conf so the Traefik checkout and webui build stay cached when only
# a plugin changes.
#
#   eval "$(tr -d '\r' < versions.conf)" && docker buildx build -f build/Dockerfile \
#     --build-arg TRAEFIK_REPO=$TRAEFIK_REPO --build-arg TRAEFIK_VERSION=$TRAEFIK_VERSION .

ARG GO_IMAGE=golang:1.26-alpine
ARG NODE_IMAGE=node:24-alpine
ARG RUNTIME_IMAGE=alpine:3.24

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS source
ARG TRAEFIK_REPO
ARG TRAEFIK_VERSION
RUN apk add --no-cache git patch
WORKDIR /src/traefik
RUN test -n "$TRAEFIK_REPO" && test -n "$TRAEFIK_VERSION" \
 && git init -q . \
 && git fetch -q --depth 1 "https://${TRAEFIK_REPO}.git" "${TRAEFIK_VERSION}" \
 && git -c advice.detachedHead=false checkout -q FETCH_HEAD

# The dashboard is architecture-independent: build it once on the build platform.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS webui
ENV VITE_APP_BASE_URL="" VITE_APP_BASE_API_URL="/api"
WORKDIR /src/webui
COPY --from=source /src/traefik/webui/ ./
RUN corepack enable && yarn install --immutable && yarn build

FROM source AS builder
ARG TRAEFIK_REPO
ARG TRAEFIK_VERSION
# Traefik can require a newer Go than the image ships; let go fetch it.
ENV GOTOOLCHAIN=auto CGO_ENABLED=0
COPY --from=webui /src/webui/static/ webui/static/
COPY versions.conf /tmp/versions.conf
COPY build/builder.patch build/integrate-plugins.sh /tmp/
COPY build/embedded-registry.go build/embedded_registry_test.go pkg/plugins/
RUN check() { \
      conf=$(sed -n "s/^$1=//p" /tmp/versions.conf | tr -d '\r'); \
      [ "$conf" = "$2" ] || { echo "build arg $1=$2 but versions.conf has $conf" >&2; exit 1; }; \
    } \
 && check TRAEFIK_REPO "$TRAEFIK_REPO" \
 && check TRAEFIK_VERSION "$TRAEFIK_VERSION"
RUN patch -p0 --forward < /tmp/builder.patch
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    sh /tmp/integrate-plugins.sh /tmp/versions.conf pkg/plugins/embedded-registry.go /out/licenses \
 && go mod tidy \
 && go test ./pkg/plugins/ -run 'Embedded'
# integrate-plugins.sh collected the plugins' licenses; add Traefik's own.
RUN mkdir -p /out/licenses/traefik && cp LICENSE.md /out/licenses/traefik/

ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    pkg=$(go list -m)/pkg/version \
 && codename=$(sed -n 's/^[[:space:]]*CODENAME:[[:space:]]*//p' .github/workflows/release.yaml | head -n 1) \
 && GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -o /out/traefik -ldflags "-s -w \
      -X $pkg.Version=$TRAEFIK_VERSION \
      -X $pkg.Codename=${codename:-cheddar} \
      -X $pkg.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      ./cmd/traefik

# Named so a manual rebuild can bypass its cache (fresh Alpine packages).
FROM ${RUNTIME_IMAGE} AS runtime
RUN apk add --no-cache --no-progress ca-certificates tzdata
COPY --from=builder /out/traefik /traefik
COPY --from=builder /out/licenses/ /licenses/
COPY build/NOTICE /licenses/NOTICE
EXPOSE 80
VOLUME ["/tmp"]
ENTRYPOINT ["/traefik"]
