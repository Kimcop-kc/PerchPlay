#!/bin/bash -e

. ../../include/depinfo.sh
. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf _build$ndk_suffix
	exit 0
else
	exit 255
fi

mkdir -p _build$ndk_suffix
cd _build$ndk_suffix

# ─────────────────────────────────────────────────────────────────────
# libplacebo —— mpv 的 vo=gpu-next 后端（hdr-toys 着色的执行引擎）
#
# 为什么必须自己编：media-kit 官方 libmpv 的 mpv.sh 里显式
#   -Dlibplacebo=disabled   -Dvulkan=disabled
# 而 hdr-toys 的 GLSL .hook 着色器只能跑在 gpu-next(=libplacebo) 上。
#
# 关键选项说明：
#   vulkan=enabled
#       启用 Vulkan 后端。**这一步决定了 pl_has_vulkan=1**，而 mpv 的
#       meson.build 里 vulkan 选项正是靠这个变量才允许开启，缺了它
#       mpv 侧 -Dvulkan=enabled 会直接报错退出。
#   shaderc=enabled
#       运行时把 GLSL 编译成 SPIR-V（hdr-toys 需要）。
#       Android NDK 自带 shaderc，前面 scripts/shaderc.sh 已编好。
#   glslang=disabled
#       用 shaderc 就不用再拉 glslang，省一次编译与体积。
#   opengl=disabled
#       只保留 Vulkan。Android 上 gpu-next 走 Vulkan 更稳，且省体积。
#   d3d11=disabled / demos / tests / bench
#       全部关掉，只要库。
#
# 注意：libplacebo 6.x 之后把版本号从 vX.Y.Z 改成了语义化分隔，
# 这里用 v7 系列（与新版 mpv 兼容；media-kit 的 mpv 78d4374 属
# 0.37 时代，用 v6.338.2 或 v7 早期都行，先用 v6.338.2 保守）。
# ─────────────────────────────────────────────────────────────────────
meson setup .. \
	--prefix="$prefix_dir" \
	--default-library static \
	--buildtype release \
	--cross-file "$prefix_dir"/crossfile.txt \
	-Dvulkan=enabled \
	-Dshaderc=enabled \
	-Dglslang=disabled \
	-Dopengl=disabled \
	-Dd3d11=disabled \
	-Dlibdovi=disabled \
	-Ddemos=false \
	-Dtests=false \
	-Dbench=false

ninja -j$cores
DESTDIR="$prefix_dir" ninja install

# ── 校验 pl_has_vulkan 是否真的写进了 pkgconfig ──
# mpv 的 meson 用 libplacebo.get_variable('pl_has_vulkan') 判断能不能开
# Vulkan。如果这里是 0，后续 mpv 的 -Dvulkan=enabled 会直接失败。
echo "=== 检查 pl_has_vulkan ==="
PC="$prefix_dir/lib/pkgconfig/libplacebo.pc"
if [ -f "$PC" ]; then
	grep -i 'pl_has_vulkan' "$PC" || echo "⚠️ pkgconfig 里没有 pl_has_vulkan 变量"
	cat "$PC"
else
	echo "⚠️ 没找到 libplacebo.pc"
	ls -la "$prefix_dir/lib/pkgconfig" || true
fi
