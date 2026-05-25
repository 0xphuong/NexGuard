#!/bin/bash
set -e

REGISTRY="docker.io"
IMAGE="binhphuong/nexguard"
BUILDER_NAME="nexguard-builder"

# ── Prompt for tag ─────────────────────────────────────────────────────────────
if [ -n "$1" ]; then
  TAG="$1"
else
  read -p "Enter image tag (e.g. 1.1.1): " TAG
fi

if [ -z "$TAG" ]; then
  echo "Error: tag cannot be empty." >&2
  exit 1
fi

FULL_IMAGE="${REGISTRY}/${IMAGE}:${TAG}"
LATEST_IMAGE="${REGISTRY}/${IMAGE}:latest"

# ── Detect Apple Silicon ───────────────────────────────────────────────────────
ARCH=$(uname -m)
USE_BUILDX=false
if [ "$ARCH" = "arm64" ]; then
  USE_BUILDX=true
  echo "Detected Apple Silicon — using docker buildx to avoid QEMU segfault."
fi

echo ""
echo "Building:  ${FULL_IMAGE}"
echo "Platform:  linux/amd64"
echo ""

# ── Build ──────────────────────────────────────────────────────────────────────
if [ "$USE_BUILDX" = "true" ]; then
  # Install QEMU emulators if not already done
  docker run --privileged --rm tonistiigi/binfmt --install amd64 > /dev/null 2>&1 || true

  # Create or reuse a buildx builder with docker-container driver
  if ! docker buildx inspect "${BUILDER_NAME}" > /dev/null 2>&1; then
    docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use
  else
    docker buildx use "${BUILDER_NAME}"
  fi

  docker buildx build \
    --platform linux/amd64 \
    -f Dockerfile.prod \
    --build-arg VERSION="${TAG}" \
    -t "${FULL_IMAGE}" \
    -t "${LATEST_IMAGE}" \
    --load \
    .
else
  docker build \
    --platform linux/amd64 \
    -f Dockerfile.prod \
    --build-arg VERSION="${TAG}" \
    -t "${FULL_IMAGE}" \
    -t "${LATEST_IMAGE}" \
    .
fi

echo ""
echo "Build complete. Push now?"
echo "  1) Push ${FULL_IMAGE} + latest"
echo "  2) Push ${FULL_IMAGE} only"
echo "  3) Skip push"
read -p "Choice [1/2/3]: " CHOICE

case "$CHOICE" in
  1)
    docker push "${FULL_IMAGE}"
    docker push "${LATEST_IMAGE}"
    echo "Pushed: ${FULL_IMAGE}"
    echo "Pushed: ${LATEST_IMAGE}"
    ;;
  2)
    docker push "${FULL_IMAGE}"
    echo "Pushed: ${FULL_IMAGE}"
    ;;
  *)
    echo "Skipped push."
    ;;
esac
