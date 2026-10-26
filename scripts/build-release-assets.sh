#!/usr/bin/env bash
# Build what a release ships: setup-otp-target.sh pinned to the release tag,
# vault-ssh-helper for amd64 and arm64, and SHA256SUMS for all of them.
#   scripts/build-release-assets.sh v0.2.0 dist
set -euo pipefail

tag=${1:?usage: $0 TAG OUT_DIR} out=${2:?usage: $0 TAG OUT_DIR}
here=$(cd "$(dirname "$0")" && pwd)
helper_version=$(sed -n 's/^HELPER_VERSION=//p' "$here/setup-otp-target.sh")
mkdir -p "$out" && out=$(cd "$out" && pwd)

sed "s/^SCRIPT_VERSION=latest\$/SCRIPT_VERSION=$tag/" "$here/setup-otp-target.sh" > "$out/setup-otp-target.sh"
grep -qx "SCRIPT_VERSION=$tag" "$out/setup-otp-target.sh" || { echo "could not pin SCRIPT_VERSION" >&2; exit 1; }

# Same Go toolchain the helper has always been built with.
for arch in amd64 arm64; do
  docker run --rm -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH="$arch" -e GOBIN= -v "$out:/out" golang:1.27 sh -c \
    "go install github.com/hashicorp/vault-ssh-helper@$helper_version \
     && cp \$(find /go/bin -name vault-ssh-helper -type f) /out/vault-ssh-helper-linux-$arch \
     && chown $(id -u):$(id -g) /out/vault-ssh-helper-linux-$arch"
done

(cd "$out" && sha256sum setup-otp-target.sh vault-ssh-helper-linux-* > SHA256SUMS)
ls -l "$out"
