#!/bin/bash
set -e  # 遇到错误立即退出

# 克隆指定版本的内核源码
git clone https://github.com/fusion-hxf/linux-raphael.git --branch 7.1 --depth 1 linux

# 应用 builddeb 补丁
patch linux/scripts/package/builddeb < builddeb.patch

cd linux
# 不再为这个补丁 commit：commit 会改变 HEAD，使内核版本里的 -g<hash> 偏离上游提交、无法追踪。
# 改用 assume-unchanged 让 scripts/setlocalversion 的 dirty 检查（git status / git diff-index）
# 忽略这个本地改动，从而内核版本 = ${KERNELVERSION}-sm8150-g<上游 HEAD 前 12 位>，
# 与 linux-raphael@7.1 的最新提交一致（补丁内容仍在工作树中生效）。
git update-index --assume-unchanged scripts/package/builddeb
echo "内核版本将使用上游 HEAD 短 hash: -g$(git rev-parse HEAD | cut -c1-12)"

# 生成内核配置
cp ../raphael.config arch/arm64/configs/
make -j$(nproc) ARCH=arm64 LLVM=-22 defconfig raphael.config

# 编译内核
make -j$(nproc) ARCH=arm64 LLVM=-22 deb-pkg

cd ..

# 重命名生成的 deb 包
IMAGE_DEB=$(ls -1 linux-image-*.deb 2>/dev/null | grep -v '\-dbg_' | head -n1)
HEADERS_DEB=$(ls -1 linux-headers-*.deb 2>/dev/null | head -n1)

if [ -n "$IMAGE_DEB" ]; then
  mv "$IMAGE_DEB" linux-image-xiaomi-raphael.deb
fi
if [ -n "$HEADERS_DEB" ]; then
  mv "$HEADERS_DEB" linux-headers-xiaomi-raphael.deb
fi

# 清理源码目录
rm -rf linux

# 构建 deb 包
dpkg-deb --build --root-owner-group firmware-xiaomi-raphael
dpkg-deb --build --root-owner-group alsa-xiaomi-raphael
