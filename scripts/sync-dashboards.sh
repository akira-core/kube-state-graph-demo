#!/usr/bin/env bash
# Copy the panel repo's provisioned dashboards into the umbrella chart.
#
# The chart cannot read them in place: Helm's .Files only sees the chart
# directory, and the panel is a submodule beside it. Copying keeps the demo's
# dashboards identical to the ones the panel repo ships and reviews.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${repo_root}/kube-state-graph-panel/provisioning/dashboards"
dst="${repo_root}/charts/ksg-demo/dashboards"

if [[ ! -d "${src}" ]]; then
  echo "error: ${src} not found — run 'git submodule update --init' first" >&2
  exit 1
fi

mkdir -p "${dst}"
rm -f "${dst}"/*.json
cp "${src}"/*.json "${dst}/"

echo "synced dashboards into charts/ksg-demo/dashboards:"
ls -1 "${dst}"
