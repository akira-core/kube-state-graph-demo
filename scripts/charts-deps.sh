#!/usr/bin/env bash
# Materialise charts/ksg-demo/charts/ without touching the network.
#
# `helm dependency update` cannot be part of `make up`: it re-resolves every
# dependency against its upstream repo index, so a demo brought up on a
# disconnected laptop fails before a single pod is scheduled.
#
# The two kinds of dependency are therefore handled differently:
#
#   upstream (victoria-metrics-cluster, kube-state-metrics,
#   opentelemetry-collector, grafana) — vendored into git UNPACKED, as plain
#   directories rather than .tgz. Helm loads either, and a directory is
#   reviewable: a version bump shows up as a diff instead of an opaque binary
#   blob. Pinned by Chart.lock, refreshed only by `make vendor-charts`.
#   Verified here, version included.
#
#   first-party (kube-state-graph, netapp-faker, demo-workloads) — packaged
#   from charts/<name>/ on every run and deliberately NOT committed. They are
#   the only dependencies whose content changes between commits, and a
#   committed copy would be a second, staler source of truth: edit
#   demo-workloads/values.yaml, forget to repackage, and the install would
#   silently use the old one.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
umbrella="${repo_root}/charts/ksg-demo"
dest="${umbrella}/charts"
lock="${umbrella}/Chart.lock"
helm_bin="${HELM_BIN:-helm}"

local_charts=(kube-state-graph netapp-faker demo-workloads)

if [[ ! -f "${lock}" ]]; then
  echo "error: ${lock} not found — the dependency pins live there" >&2
  exit 1
fi

mkdir -p "${dest}"

echo "==> packaging the first-party subcharts"
for chart in "${local_charts[@]}"; do
  src="${repo_root}/charts/${chart}"
  if [[ ! -d "${src}" ]]; then
    echo "error: ${src} not found" >&2
    exit 1
  fi
  # Remove first: a version bump in the subchart's Chart.yaml would otherwise
  # leave the old archive behind and Helm would load both.
  rm -f "${dest}/${chart}"-*.tgz
  "${helm_bin}" package "${src}" --destination "${dest}" >/dev/null
  printf '    built    %s\n' "$(basename "$(ls "${dest}/${chart}"-*.tgz)")"
done

echo "==> checking the vendored upstream subcharts"
missing=0
while IFS=$'\t' read -r name repo version; do
  [[ -n "${name}" ]] || continue
  # file:// entries are the first-party charts packaged above.
  [[ "${repo}" == file://* ]] && continue

  chart_yaml="${dest}/${name}/Chart.yaml"
  if [[ ! -f "${chart_yaml}" ]]; then
    printf '    MISSING  %-32s (no charts/%s/ directory)\n' "${name}" "${name}"
    missing=$(( missing + 1 ))
    continue
  fi

  # Assert the vendored copy is the version Chart.lock pins. Helm itself does
  # not re-check this for an unpacked subchart, so a hand-edited or half-updated
  # directory would otherwise install silently.
  have="$(awk '/^version:[[:space:]]/ { print $2; exit }' "${chart_yaml}")"
  if [[ "${have}" == "${version}" ]]; then
    printf '    ok       %-32s %s\n' "${name}" "${version}"
  else
    printf '    STALE    %-32s vendored %s, Chart.lock pins %s\n' "${name}" "${have:-?}" "${version}"
    missing=$(( missing + 1 ))
  fi
done < <(awk '
  function flush() { if (name != "") print name "\t" repo "\t" ver }
  /^- name: /       { flush(); name=$3; repo=""; ver="" }
  /^  repository: / { repo=$2 }
  /^  version: /    { ver=$2 }
  END               { flush() }
' "${lock}")

if (( missing > 0 )); then
  cat >&2 <<MSG

error: ${missing} vendored subchart(s) missing or out of sync.

       They are committed so that 'make up' installs with no network. Restore
       them from git:

           git checkout -- charts/ksg-demo/charts

       or, if a pin in Chart.yaml changed, refresh them online with:

           make vendor-charts

MSG
  exit 1
fi
