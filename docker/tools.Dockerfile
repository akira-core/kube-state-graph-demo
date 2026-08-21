# Build context: tools/
#
# One image carries both demo binaries. They are unrelated at runtime but share
# a module, and a single image means a single `kind load` in the bring-up path.
FROM golang:1.26.6-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
        -o /out/ ./cmd/demo-app ./cmd/netapp-faker

# distroless/static: both binaries are pure Go with no dynamic linkage.
FROM gcr.io/distroless/static:nonroot

COPY --from=build /out/demo-app /usr/local/bin/demo-app
COPY --from=build /out/netapp-faker /usr/local/bin/netapp-faker

USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/demo-app"]
