#!/usr/bin/env sh

VERSION=0.1.0

set -eu

_name=arm64
_platform="linux/arm64"
_runtime_base="arm64v8/debian:bookworm-slim"
_out="certbot-multidevice-${_name}.tar"

echo ">>> Building ${_name}  (${_platform}, base ${_runtime_base}) -> ${_out}"
rm -f "${_out}"

docker buildx build \
  --no-cache \
  --build-arg RUNTIME_BASE="${_runtime_base}" \
  --platform "${_platform}" \
  --load -t "certbot-multidevice:${VERSION}-${_name}" .

skopeo copy \
  "docker-daemon:certbot-multidevice:${VERSION}-${_name}" \
  "docker-archive:${_out}"

echo ">>> Done: ${_out}"
ls -lh certbot-multidevice-*.tar 2>/dev/null || true
