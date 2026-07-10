# Raphael Kernel Deb Builder

本仓库负责把 `linux-raphael` 内核源码构建为 raphael 设备使用的 deb 包：

- `linux-image-xiaomi-raphael.deb`
- `linux-headers-xiaomi-raphael.deb`
- `firmware-xiaomi-raphael.deb`
- `alsa-xiaomi-raphael.deb`

当前默认内核来源为 `7.1` 分支。该分支已确认停在音频 bring-up 节点；前一轮视频驱动相关尝试已判定无效，不作为默认构建来源。

## 本地构建

在聚合仓库中运行时，脚本会优先使用 `../linux`，再 checkout `KERNEL_REF`：

```bash
bash raphael-kernel_build.sh 7.1
```

强制从远端拉取：

```bash
USE_LOCAL_KERNEL=0 KERNEL_REF=7.1 bash raphael-kernel_build.sh 7.1
```

保留临时源码目录用于排查：

```bash
KEEP_WORKDIR=1 bash raphael-kernel_build.sh 7.1
```

## 常用参数

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `KERNEL_REPO` | `https://github.com/fusion-hxf/linux-raphael.git` | 内核源码仓库 |
| `KERNEL_REF` | 与版本号一致，如 `7.1` | 分支、标签或提交 |
| `KERNEL_SOURCE_DIR` | 空 | 显式指定本地内核源码路径 |
| `USE_LOCAL_KERNEL` | `auto` | `auto` 会优先使用 `../linux`；设为 `0` 强制远端 |
| `KERNEL_PACKAGE_TARGET` | `bindeb-pkg` | 可改为 `deb-pkg` |
| `LLVM_VERSION` | `22` | 使用 `LLVM=-<version>` |
| `JOBS` | CPU 数 | 并行编译数 |
| `OUT_DIR` | 当前仓库根 | 产物输出目录 |
| `KEEP_WORKDIR` | `0` | `1` 表示保留 `.build-kernel/` |

脚本会输出 `kernel-build-info.env` 和 `kernel-build-summary.md`，CI 会把它们一并上传和发布。

## CI

`.github/workflows/编译kernel.yml` 仅手动触发。主要输入：

- `kernel_version`
- `kernel_repo`
- `kernel_ref`
- `package_target`
- `llvm_version`
- `publish_release`
- `release_tag`

CI 中显式设置 `USE_LOCAL_KERNEL=0`，保证云端构建只使用 workflow 输入的源码仓库和 ref。

