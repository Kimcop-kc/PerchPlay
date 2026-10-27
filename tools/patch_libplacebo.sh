#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# 为 media-kit 的 libmpv Android 构建链接入 libplacebo（hdr-toys 前置）
#
# 背景：media-kit 官方 libmpv 的 mpv.sh 显式
#         -Dlibplacebo=disabled   -Dvulkan=disabled
#       而 hdr-toys 的 GLSL .hook 着色器**必须** libplacebo + vo=gpu-next。
#       mpv 的 meson.build 里 gpu-next 的定义就是：
#         summary({'gpu-next': features['libplacebo'], ...})
#
# 这个脚本做 4 件事：
#   1. 复制 libplacebo 构建脚本到 scripts/
#   2. depinfo.sh 加版本号 + 依赖关系
#   3. download-deps.sh 加源码下载（该文件是显式逐条列出的）
#   4. mpv.sh 开 libplacebo / vulkan / shaderc
#
# 用法：patch_libplacebo.sh <libmpv-android-video-build 仓库根> <本仓库 tools 目录>
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

BUILD_REPO="${1:?需要 media-kit 构建仓库路径}"
TOOLS_DIR="${2:?需要本仓库 tools 目录路径}"

BS="$BUILD_REPO/buildscripts"
[ -d "$BS" ] || { echo "❌ 找不到 $BS"; exit 1; }

LP_VERSION="6.338.2"

echo "=== 1) 复制 libplacebo 构建脚本 ==="
cp "$TOOLS_DIR/libplacebo.sh" "$BS/scripts/libplacebo.sh"
chmod +x "$BS/scripts/libplacebo.sh"

echo "=== 2) depinfo.sh：版本号 + 依赖关系 ==="
DEP="$BS/include/depinfo.sh"
if ! grep -q '^v_libplacebo=' "$DEP"; then
  sed -i "/^v_libvpx=/a v_libplacebo=${LP_VERSION}" "$DEP"
fi
if ! grep -q '^dep_libplacebo=' "$DEP"; then
  # libplacebo 依赖 shaderc（运行时 GLSL→SPIR-V）
  sed -i '/^dep_shaderc=()/a dep_libplacebo=(shaderc)' "$DEP"
fi
# 接进 mpv 依赖列表（两种变体都要）
sed -i 's/^\(\s*\)dep_mpv=(ffmpeg libass)$/\1dep_mpv=(ffmpeg libass libplacebo)/' "$DEP"
sed -i 's/^\(\s*\)dep_mpv=(ffmpeg libass fftools_ffi)$/\1dep_mpv=(ffmpeg libass fftools_ffi libplacebo)/' "$DEP"

echo "=== 3) download-deps.sh：加 libplacebo 源码下载 ==="
DLS="$BS/include/download-deps.sh"
if ! grep -q 'libplacebo' "$DLS"; then
  # 插在 shaderc 之前（保持逻辑顺序：shaderc 是 libplacebo 的依赖）
  python3 - "$DLS" "$LP_VERSION" <<'PYEOF'
import sys
path, ver = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8').read()
anchor = '# shaderc\n'
block = (
    '# libplacebo（mpv 的 vo=gpu-next 后端 / hdr-toys 着色引擎）\n'
    '[ ! -d libplacebo ] && git clone --depth 1 --branch v' + ver +
    ' --recursive https://github.com/haasn/libplacebo.git libplacebo\n\n'
)
if anchor in src:
    src = src.replace(anchor, block + anchor, 1)
else:
    src += '\n' + block
open(path, 'w', encoding='utf-8').write(src)
print('  已插入 libplacebo 下载')
PYEOF
fi

echo "=== 4) mpv.sh：开启 libplacebo / vulkan / shaderc / plain-gl ==="
MPVSH="$BS/scripts/mpv.sh"
sed -i 's/-Dvulkan=disabled/-Dvulkan=enabled/' "$MPVSH"
sed -i 's/-Dlibplacebo=disabled/-Dlibplacebo=enabled/' "$MPVSH"
# shaderc + spirv-cross：libplacebo 运行时编译 GLSL 需要
if ! grep -q 'Dshaderc=enabled' "$MPVSH"; then
  sed -i 's/-Dvulkan=enabled/-Dvulkan=enabled \\\n\t-Dshaderc=enabled \\\n\t-Dspirv-cross=enabled/' "$MPVSH"
fi
# plain-gl：libmpv（非 cplayer）场景下 gpu-next 需要它才能建上下文
if ! grep -q 'Dplain-gl=enabled' "$MPVSH"; then
  sed -i 's/-Dshaderc=enabled/-Dplain-gl=enabled \\\n\t-Dshaderc=enabled/' "$MPVSH"
fi

echo ""
echo "=== 校验 ==="
echo "--- depinfo.sh ---"
grep -nE 'v_libplacebo|dep_libplacebo|dep_mpv' "$DEP" || true
echo "--- download-deps.sh ---"
grep -n 'libplacebo' "$DLS" || true
echo "--- mpv.sh ---"
grep -nE 'libplacebo|vulkan|shaderc|spirv|plain-gl' "$MPVSH" || true

echo ""
FAIL=0
grep -q 'v_libplacebo=' "$DEP" || { echo "❌ 版本号未插入"; FAIL=1; }
grep -q 'libplacebo' "$DLS" || { echo "❌ 下载项未插入"; FAIL=1; }
grep -q 'Dlibplacebo=enabled' "$MPVSH" || { echo "❌ mpv.sh 未开启 libplacebo"; FAIL=1; }
grep -q 'Dvulkan=enabled' "$MPVSH" || { echo "❌ mpv.sh 未开启 vulkan"; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then
  echo "✅ patch 完成"
else
  echo "❌ patch 有缺失"
  exit 1
fi
