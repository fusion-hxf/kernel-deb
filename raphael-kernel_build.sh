#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KERNEL_VERSION="${1:-${KERNEL_VERSION:-7.1}}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/fusion-hxf/linux-raphael.git}"
# 7.1 当前指向音频 bring-up 节点；视频相关尝试已确认无效，不作为默认来源。
KERNEL_REF="${KERNEL_REF:-$KERNEL_VERSION}"
KERNEL_SOURCE_DIR="${KERNEL_SOURCE_DIR:-}"
USE_LOCAL_KERNEL="${USE_LOCAL_KERNEL:-auto}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/.build-kernel}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc)}"
LLVM_VERSION="${LLVM_VERSION:-22}"
LLVM_FLAG="${LLVM_FLAG:--$LLVM_VERSION}"
KERNEL_PACKAGE_TARGET="${KERNEL_PACKAGE_TARGET:-bindeb-pkg}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"

SRC_DIR="$WORK_DIR/linux"
CONFIG_FILE="$SCRIPT_DIR/raphael.config"
BUILDDEB_PATCH="$SCRIPT_DIR/builddeb.patch"
INFO_FILE="$OUT_DIR/kernel-build-info.env"
SUMMARY_FILE="$OUT_DIR/kernel-build-summary.md"
KERNEL_SOURCE_LABEL="$KERNEL_REPO"

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

need_file() {
  [ -f "$1" ] || die "缺少文件: $1"
}

checkout_ref() {
  local ref="$1"

  if git -C "$SRC_DIR" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    git -C "$SRC_DIR" checkout --quiet --detach "$ref"
    return
  fi

  if git -C "$SRC_DIR" rev-parse --verify --quiet "origin/$ref^{commit}" >/dev/null; then
    git -C "$SRC_DIR" checkout --quiet --detach "origin/$ref"
    return
  fi

  git -C "$SRC_DIR" fetch --depth 1 origin "$ref" >/dev/null 2>&1 \
    || git -C "$SRC_DIR" fetch origin "$ref" >/dev/null 2>&1 \
    || die "无法获取内核 ref: $ref"
  git -C "$SRC_DIR" checkout --quiet --detach FETCH_HEAD
}

clone_kernel() {
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR" "$OUT_DIR"

  if [ -z "$KERNEL_SOURCE_DIR" ] && [ "$USE_LOCAL_KERNEL" != "0" ] && [ -d "$SCRIPT_DIR/../linux/.git" ]; then
    KERNEL_SOURCE_DIR="$SCRIPT_DIR/../linux"
  fi

  if [ -n "$KERNEL_SOURCE_DIR" ]; then
    KERNEL_SOURCE_LABEL="$KERNEL_SOURCE_DIR"
    log "使用本地内核源码: $KERNEL_SOURCE_DIR"
    git clone --no-local "$KERNEL_SOURCE_DIR" "$SRC_DIR"
    checkout_ref "$KERNEL_REF"
    return
  fi

  log "克隆内核源码: $KERNEL_REPO @ $KERNEL_REF"
  if ! git clone --depth 1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$SRC_DIR"; then
    log "浅克隆指定分支失败，改用普通克隆后 checkout ref"
    rm -rf "$SRC_DIR"
    git clone "$KERNEL_REPO" "$SRC_DIR"
    checkout_ref "$KERNEL_REF"
  fi
}

apply_builddeb_patch() {
  need_file "$BUILDDEB_PATCH"

#   cd linux
# # 不再为这个补丁 commit：commit 会改变 HEAD，使内核版本里的 -g<hash> 偏离上游提交、无法追踪。
# # 改用 assume-unchanged 让 scripts/setlocalversion 的 dirty 检查（git status / git diff-index）
# # 忽略这个本地改动，从而内核版本 = ${KERNELVERSION}-sm8150-g<上游 HEAD 前 12 位>，
# # 与 linux-raphael@7.1 的最新提交一致（补丁内容仍在工作树中生效）。
# git update-index --assume-unchanged scripts/package/builddeb
# echo "内核版本将使用上游 HEAD 短 hash: -g$(git rev-parse HEAD | cut -c1-12)"

  if patch -d "$SRC_DIR" -p1 --forward --dry-run < "$BUILDDEB_PATCH" >/dev/null 2>&1; then
    log "应用 builddeb DTB 打包补丁"
    patch -d "$SRC_DIR" -p1 --forward < "$BUILDDEB_PATCH"
    return
  fi

  if patch -d "$SRC_DIR" -p1 --reverse --dry-run < "$BUILDDEB_PATCH" >/dev/null 2>&1; then
    log "builddeb 补丁已经存在，跳过"
    return
  fi

  die "builddeb.patch 无法干净应用"
}

commit_build_inputs() {
  need_file "$CONFIG_FILE"
  install -m 0644 "$CONFIG_FILE" "$SRC_DIR/arch/arm64/configs/raphael.config"

  if git -C "$SRC_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SRC_DIR" add scripts/package/builddeb arch/arm64/configs/raphael.config
    if ! git -C "$SRC_DIR" diff --cached --quiet; then
      log "提交临时构建输入，保持 KERNELRELEASE 稳定"
      git -C "$SRC_DIR" \
        -c user.name="kernel-deb builder" \
        -c user.email="builder@localhost" \
        commit --quiet -m "build: apply raphael deb packaging inputs"
    fi
  fi
}

build_kernel_debs() {
  local make_args=(ARCH=arm64 LLVM="$LLVM_FLAG")

  log "生成配置: defconfig + raphael.config"
  make -C "$SRC_DIR" -j"$JOBS" "${make_args[@]}" defconfig raphael.config

  log "编译内核 deb: target=$KERNEL_PACKAGE_TARGET jobs=$JOBS LLVM=$LLVM_FLAG"
  make -C "$SRC_DIR" -j"$JOBS" "${make_args[@]}" "$KERNEL_PACKAGE_TARGET"
}

copy_kernel_debs() {
  local image_deb headers_deb

  image_deb="$(find "$WORK_DIR" -maxdepth 1 -type f -name 'linux-image-*.deb' ! -name '*-dbg*' | sort | tail -n 1 || true)"
  headers_deb="$(find "$WORK_DIR" -maxdepth 1 -type f -name 'linux-headers-*.deb' | sort | tail -n 1 || true)"

  [ -n "$image_deb" ] || die "未找到 linux-image deb"
  [ -n "$headers_deb" ] || die "未找到 linux-headers deb"

  cp -f "$image_deb" "$OUT_DIR/linux-image-xiaomi-raphael.deb"
  cp -f "$headers_deb" "$OUT_DIR/linux-headers-xiaomi-raphael.deb"
}

build_static_debs() {
  log "构建 firmware / ALSA deb"
  dpkg-deb --build --root-owner-group "$SCRIPT_DIR/firmware-xiaomi-raphael" "$OUT_DIR/firmware-xiaomi-raphael.deb"
  dpkg-deb --build --root-owner-group "$SCRIPT_DIR/alsa-xiaomi-raphael" "$OUT_DIR/alsa-xiaomi-raphael.deb"
}

validate_outputs() {
  local deb

  for deb in \
    "$OUT_DIR/linux-image-xiaomi-raphael.deb" \
    "$OUT_DIR/linux-headers-xiaomi-raphael.deb" \
    "$OUT_DIR/firmware-xiaomi-raphael.deb" \
    "$OUT_DIR/alsa-xiaomi-raphael.deb"; do
    [ -s "$deb" ] || die "产物为空或不存在: $deb"
  done

  if ! dpkg-deb -c "$OUT_DIR/linux-image-xiaomi-raphael.deb" | grep -q 'sm8150-xiaomi-raphael.dtb'; then
    die "linux-image deb 中未找到 sm8150-xiaomi-raphael.dtb"
  fi

  log "产物摘要:"
  for deb in "$OUT_DIR"/*.deb; do
    printf '  - %s: %s %s %s\n' \
      "$(basename "$deb")" \
      "$(dpkg-deb -f "$deb" Package)" \
      "$(dpkg-deb -f "$deb" Version)" \
      "$(dpkg-deb -f "$deb" Architecture)"
  done
}

write_build_info() {
  shell_quote() {
    printf '%q' "$1"
  }

  cat > "$INFO_FILE" <<EOF
KERNEL_VERSION=$(shell_quote "$KERNEL_VERSION")
KERNEL_REPO=$(shell_quote "$KERNEL_REPO")
KERNEL_SOURCE=$(shell_quote "$KERNEL_SOURCE_LABEL")
KERNEL_REF=$(shell_quote "$KERNEL_REF")
KERNEL_SOURCE_COMMIT=$(shell_quote "$SOURCE_COMMIT")
KERNEL_SOURCE_SUBJECT=$(shell_quote "$SOURCE_SUBJECT")
KERNEL_BUILD_COMMIT=$(shell_quote "$(git -C "$SRC_DIR" rev-parse HEAD)")
KERNEL_PACKAGE_TARGET=$(shell_quote "$KERNEL_PACKAGE_TARGET")
LLVM_FLAG=$(shell_quote "$LLVM_FLAG")
JOBS=$(shell_quote "$JOBS")
EOF

  cat > "$SUMMARY_FILE" <<EOF
# Raphael kernel deb build

- Kernel version: \`$KERNEL_VERSION\`
- Source: \`$KERNEL_SOURCE_LABEL\`
- Ref: \`$KERNEL_REF\`
- Source commit: \`$SOURCE_COMMIT\` - $SOURCE_SUBJECT
- Package target: \`$KERNEL_PACKAGE_TARGET\`
- LLVM: \`$LLVM_FLAG\`
- Jobs: \`$JOBS\`

## Artifacts

$(for deb in "$OUT_DIR"/*.deb; do printf -- '- `%s`\n' "$(basename "$deb")"; done)
EOF
}

cleanup() {
  if [ "$KEEP_WORKDIR" = "1" ]; then
    log "保留工作目录: $WORK_DIR"
  else
    rm -rf "$WORK_DIR"
  fi
}

main() {
  need_file "$CONFIG_FILE"

  log "Raphael 内核 deb 构建开始"
  log "默认内核 ref: $KERNEL_REF（当前应为音频 bring-up 节点）"

  clone_kernel
  SOURCE_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
  SOURCE_SUBJECT="$(git -C "$SRC_DIR" show -s --format=%s HEAD)"
  log "内核源码提交: $SOURCE_COMMIT $SOURCE_SUBJECT"

  apply_builddeb_patch
  commit_build_inputs
  build_kernel_debs
  copy_kernel_debs
  build_static_debs
  validate_outputs
  write_build_info

  log "构建完成: $OUT_DIR"
  cleanup
}

main "$@"
