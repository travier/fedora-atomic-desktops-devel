#!/bin/bash

# SPDX-FileCopyrightText: Timothée Ravier <tim@siosm.fr>
# SPDX-License-Identifier: CC0-1.0

set -euo pipefail
# set -x

variants=(
    'base-atomic'
    'silverblue'
    'kinoite'
    'kinoite-mobile'
    'sway-atomic'
    'budgie-atomic'
    'cosmic-atomic'
)
arches=(
    "x86_64"
    "aarch64"
)

branch="$(git rev-parse --abbrev-ref HEAD)"
release=""
if [[ "${branch}" == "main" ]] || [[ -f "fedora-rawhide.repo" ]]; then
    release="rawhide"
    branch="main"
else
    release="$(rpm-ostree compose tree --print-only --repo=repo silverblue.yaml | jq -r '."releasever"')"
    branch="f${release}"
fi
buildroot="quay.io/fedora-ostree-desktops/buildroot:${release}"

{
cat <<EOF
# SPDX-FileCopyrightText: Timothée Ravier <tim@siosm.fr>
# SPDX-License-Identifier: CC0-1.0

name: "Build Bootable Container images"

env:
  REGISTRY: "quay.io/fedora-atomic-desktops-staging"
  RELEASE: "${release}"

on:
  push:
    branches:
      - "${branch}"
  pull_request:
    branches:
      - "${branch}"
  workflow_dispatch:

permissions: read-all

# Prevent multiple workflow runs from racing to ensure that pushes are made
# sequentialy for the main branch. Also cancel in progress workflow runs for
# pull requests only.
concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true

jobs:
EOF

for variant in "${variants[@]}"; do
    for arch in "${arches[@]}"; do
        runs_on="ubuntu-24.04"
        if [[ "${arch}" == "aarch64" ]]; then
            runs_on="ubuntu-24.04-arm"
        fi
        cat <<EOF

  build-${variant}-${arch}:
    runs-on: ${runs_on}
    container:
      image: ${buildroot}
      options: --security-opt=label=disable --privileged --user 0:0 --device=/dev/kvm --device=/dev/fuse --volume /:/run/host:rw --pid=host
    outputs:
      version: \${{ steps.build-push.outputs.version }}
      digest: \${{ steps.build-push.outputs.digest }}
      registry-path: \${{ steps.build-push.outputs.registry-path }}
      tag: \${{ steps.build-push.outputs.tag }}
    steps:
      - name: "Checkout repo"
        uses: actions/checkout@v4
      - name: "Runner setup"
        uses: ./.github/actions/setup
      - name: "Build and push container image"
        uses: ./.github/actions/build-push
        id: build-push
        with:
          variant: "${variant}"
          release: \${{ env.RELEASE }}
          registry: \${{ env.REGISTRY }}
          username: \${{ secrets.BOT_USERNAME }}
          password: \${{ secrets.BOT_SECRET }}
          cosign-private-key: \${{ secrets.COSIGN_PRIVATE_KEY}}
EOF
    done

    # Default to empty config. Overriden if not Silverblue or Kinoite
    bib_config="./bib-empty.toml"
    if [[ "${variant}" != "silverblue" ]] && [[ "${variant}" != "kinoite" ]]; then
        bib_config="./bib-fedora.toml"
    fi
    cat <<EOF

  multi-arch-${variant}:
    runs-on: ubuntu-24.04
    needs:
      - build-${variant}-x86_64
      - build-${variant}-aarch64
    if: (github.event_name == 'push' || github.event_name == 'schedule' || github.event_name == 'workflow_dispatch')
    steps:
      - name: "Checkout repo"
        uses: actions/checkout@v4
      - name: "Runner setup"
        uses: ./.github/actions/setup
      - name: "Create multi-arch manifest"
        uses: ./.github/actions/multi-arch
        with:
          version: \${{ needs.build-${variant}-x86_64.outputs.version }}
          release: \${{ env.RELEASE }}
          registry-path: \${{ needs.build-${variant}-x86_64.outputs.registry-path }}
          image-x86_64: \${{ needs.build-${variant}-x86_64.outputs.registry-path }}:\${{ needs.build-${variant}-x86_64.outputs.tag }}
          image-aarch64: \${{ needs.build-${variant}-aarch64.outputs.registry-path }}:\${{ needs.build-${variant}-aarch64.outputs.tag }}
          registry: \${{ env.REGISTRY }}
          username: \${{ secrets.BOT_USERNAME }}
          password: \${{ secrets.BOT_SECRET }}
          cosign-private-key: \${{ secrets.COSIGN_PRIVATE_KEY}}

  qcow2-${variant}-x86_64:
    runs-on: ubuntu-24.04
    needs:
      - build-${variant}-x86_64
    steps:
      - name: "Checkout repo"
        uses: actions/checkout@v4
      - name: "Runner setup"
        uses: ./.github/actions/setup
      - name: "Build QCOW2 image"
        uses: ./.github/actions/qcow2
        with:
          registry: \${{ env.REGISTRY }}
          image: \${{ needs.build-${variant}-x86_64.outputs.registry-path }}:\${{ needs.build-${variant}-x86_64.outputs.tag }}
          variant: "${variant}"
          release: \${{ env.RELEASE }}
          bib-config: "${bib_config}"
          username: \${{ secrets.BOT_USERNAME }}
          password: \${{ secrets.BOT_SECRET }}
          cosign-private-key: \${{ secrets.COSIGN_PRIVATE_KEY}}
EOF
done
} > .github/workflows/bootable-containers.yml
