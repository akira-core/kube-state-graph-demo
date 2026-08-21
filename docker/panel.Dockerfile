# Build context: kube-state-graph-panel/ (the submodule).
#
# The result is not a server — it is a file carrier. Grafana loads panel plugins
# from disk, so an init container copies /plugin out of this image into the
# Grafana pod's plugin directory. Building the bundle here (rather than bind
# mounting a host dist/) keeps `make up` working on a clean checkout with no
# Node toolchain installed.
FROM node:22-alpine AS build

WORKDIR /src

# npm ci needs both files and is cached as one layer: dependency installs
# dominate this build, and they only change when the lockfile does.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .
RUN npm run build

FROM busybox:1.37

# The directory name must match the plugin id in plugin.json — Grafana keys the
# unsigned-plugin allowlist (GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS) off it.
COPY --from=build /src/dist /plugin

CMD ["true"]
