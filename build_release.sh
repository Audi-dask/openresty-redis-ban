#!/bin/bash
set -euo pipefail

# 用法：./build_release.sh [linux|mac]
# 默认：linux，构建可部署到 Linux x86_64 服务器的镜像。
# mac：构建可在 Apple Silicon Mac 的 Docker Desktop 中运行的 Linux ARM64 镜像。

PLATFORM=${1:-linux}
IMAGE_REPO=${IMAGE_REPO:-openresty-redis-ban}
IMAGE_TAG=${IMAGE_TAG:-$(date +%Y%m%d-%H%M%S)}

case "$PLATFORM" in
    linux)
        TARGET_PLATFORM="linux/amd64"
        echo "目标平台：Linux x86_64"
        ;;
    mac|darwin)
        TARGET_PLATFORM="linux/arm64"
        echo "目标平台：Apple Silicon Mac（Linux ARM64 容器）"
        ;;
    *)
        echo "不支持的平台：$PLATFORM" >&2
        echo "用法：./build_release.sh [linux|mac]" >&2
        exit 1
        ;;
esac

FULL_IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
LATEST_IMAGE="${IMAGE_REPO}:latest"

echo "开始构建 OpenResty WAF 镜像..."
echo "镜像版本：${FULL_IMAGE}"

if ! docker buildx version >/dev/null 2>&1; then
    echo "Docker Buildx 不可用，请先安装或启用 Buildx。" >&2
    exit 1
fi

docker buildx build \
    --platform "$TARGET_PLATFORM" \
    --tag "$FULL_IMAGE" \
    --tag "$LATEST_IMAGE" \
    --load \
    .

echo "镜像构建完成："
echo "  ${FULL_IMAGE}"
echo "  ${LATEST_IMAGE}"
echo
echo "启动服务："
echo "  docker compose up -d"
echo
echo "查看状态："
echo "  docker compose ps"
echo
echo "如需推送到镜像仓库："
echo "  docker push ${FULL_IMAGE}"
echo "  docker push ${LATEST_IMAGE}"
