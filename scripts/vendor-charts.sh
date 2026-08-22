#!/usr/bin/env bash
# Refresh the vendored upstream subcharts. NEEDS NETWORK.
#
# Run this only when a pin in charts/ksg-demo/Chart.yaml changes, then commit
# the unpacked directories together with Chart.lock — the two must move as one
# or `make deps` reports the vendored set as stale.
#
# `make up` never calls this: bring-up has to work offline.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
umbrella="${repo_root}/charts/ksg-demo"
dest="${umbrella}/charts"
lock="${umbrella}/Chart.lock"
helm_bin="${HELM_BIN:-helm}"

echo "==> resolving dependencies against the upstream repos"
"${helm_bin}" dependency update "${umbrella}"

# helm leaves everything as .tgz. Unpack the upstream ones so they land in git
# as reviewable trees; the first-party archives it also rebuilt are gitignored
# and get repackaged from source by charts-deps.sh anyway.
echo
echo "==> unpacking the upstream subcharts"
while IFS=$'\t' read -r name repo version; do
  [[ -n "${name}" ]] || continue
  [[ "${repo}" == file://* ]] && continue

  tgz="${dest}/${name}-${version}.tgz"
  if [[ ! -f "${tgz}" ]]; then
    echo "error: helm did not produce ${tgz}" >&2
    exit 1
  fi
  # Remove the old tree first so a file dropped upstream does not linger.
  rm -rf "${dest:?}/${name}"
  tar -xzf "${tgz}" -C "${dest}"
  rm -f "${tgz}"
  printf '    %-32s %s\n' "${name}" "${version}"
done < <(awk '
  function flush() { if (name != "") print name "\t" repo "\t" ver }
  /^- name: /       { flush(); name=$3; repo=""; ver="" }
  /^  repository: / { repo=$2 }
  /^  version: /    { ver=$2 }
  END               { flush() }
' "${lock}")

echo
echo "==> git sees:"
git -C "${repo_root}" status --porcelain -- charts/ksg-demo/charts charts/ksg-demo/Chart.lock \
  | sed 's/^/    /'
echo
echo "    Commit the subchart directories and Chart.lock together."
