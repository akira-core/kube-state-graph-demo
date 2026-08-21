# Build context: kube-state-graph/ (the submodule).
#
# Deliberately NOT the upstream deploy/docker/server.Dockerfile. That one also
# pulls Envoy's ~1 GB tools image for router_check_tool, which only matters for
# the optional Istio route-resolution feature (--route-store-dsn). The demo
# never sets that DSN, so the binary never execs the tool, and skipping it turns
# a multi-gigabyte pull into a plain Go build.
#
# The base Go version tracks the submodule's `toolchain` directive; a lower base
# triggers a silent mid-build toolchain download instead of failing loudly.
FROM golang:1.26.6-alpine AS build

ARG VERSION=demo

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" \
        -o /out/kube-state-graph ./cmd/kube-state-graph

# distroless/static (not /cc): with router_check_tool dropped there is no
# dynamically linked C++ binary left to satisfy.
FROM gcr.io/distroless/static:nonroot

COPY --from=build /out/kube-state-graph /usr/local/bin/kube-state-graph

USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/kube-state-graph"]
