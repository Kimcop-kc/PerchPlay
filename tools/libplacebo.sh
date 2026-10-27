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
echo "=== 前置检查：shaderc 产物是否就位 ==="
# libplacebo 的 src/glsl/meson.build 用 Dependency('shaderc')，实际需要三样：
#   1. $prefix_dir/usr/local/lib/libshaderc_combined.a   （静态库）
#   2. $prefix_dir/usr/local/lib/pkgconfig/shaderc.pc    （pkg-config 描述）
#   3. $prefix_dir/usr/local/include/shaderc/shaderc.h   （头文件）
# 缺 3 会报 'shaderc/shaderc.h' file not found。
PLIB="$prefix_dir/usr/local/lib"
for f in "$PLIB/libshaderc_combined.a" \
         "$PLIB/pkgconfig/shaderc.pc" \
         "$prefix_dir/usr/local/include/shaderc/shaderc.h"; do
	if [ -f "$f" ]; then
		echo "  ✓ $f"
	else
		echo "  ✗ 缺失: $f"
	fi
done
echo "  PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"
echo "  PKG_CONFIG_SYSROOT_DIR=$PKG_CONFIG_SYSROOT_DIR"

# ── 生成 vulkan.pc ──
# mpv 的 meson.build 用 dependency('vulkan', version: '>= 1.1.70')，
# 但 Android NDK 只提供 vulkan/vulkan.h（sysroot 内），**不带 vulkan.pc**。
# 缺了它 mpv 会报：
#   ld.lld: error: unable to find library -lvulkan
#   ERROR: Dependency "vulkan" not found (tried pkg-config and system)
# Android 的 libvulkan.so 由系统提供，但它只存在于 NDK sysroot 的
# **API level 子目录**里，例如：
#   sysroot/usr/lib/aarch64-linux-android/21/libvulkan.so
# 而不在 sysroot/usr/lib/aarch64-linux-android/ 下。所以 -lvulkan 用默认
# 搜索路径找不到，会报：
#   ld.lld: error: unable to find library -lvulkan
#
# 解决：把 libvulkan 的真实路径**直接写进 -l 的前面**。
#
# ⚠ 为什么不用 -L：
#   PKG_CONFIG_SYSROOT_DIR 被设为 $prefix_dir，pkg-config 会给 -L 里的
#   **每个路径**都拼上这个 sysroot。而 libvulkan.so 在 **NDK sysroot**
#   下（<NDK>/.../sysroot/usr/lib/aarch64-linux-android/24），不在
#   $prefix_dir 下，无论怎么写都会拼错：
#     写 /usr/lib/...          → <prefix>/usr/lib/...        ❌
#     写绝对路径 .../sysroot/... → <prefix>/.../sysroot/...  ❌
#
# 而 Libs 里**直接给 .so 文件路径**（不带 -L）时，pkg-config 不会改写它，
# 链接器拿到的是原样路径，最可靠。
echo "=== 定位 libvulkan.so ==="
VK_SO=""
TC_ROOT="$(cd "$(dirname "$(which "${CC:-cc}")")/.." && pwd)"
SYSROOT="$TC_ROOT/sysroot"
for API in 21 24 26 28 30 31 33 34; do
	TRY="$SYSROOT/usr/lib/aarch64-linux-android/$API/libvulkan.so"
	if [ -f "$TRY" ]; then
		VK_SO="$TRY"
		break
	fi
done
if [ -z "$VK_SO" ]; then
	VK_SO=$(find "$SYSROOT/usr/lib" -name 'libvulkan.so' 2>/dev/null | head -1)
fi
if [ -n "$VK_SO" ]; then
	echo "  ✓ libvulkan.so: $VK_SO"
else
	echo "  ⚠ 未找到 libvulkan.so"
fi

echo "=== 生成 vulkan.pc ==="
for VKDIR in "$prefix_dir/usr/local/lib/pkgconfig" "$prefix_dir/lib/pkgconfig"; do
	mkdir -p "$VKDIR"
	{
		echo "prefix=/usr/local"
		echo 'exec_prefix=${prefix}'
		echo 'libdir=${prefix}/lib'
		echo 'includedir=${prefix}/include'
		echo ""
		echo "Name: vulkan"
		echo "Description: Vulkan (Android NDK loader stub)"
		echo "Version: 1.3.268"
		if [ -n "$VK_SO" ]; then
			# 直接给 .so 绝对路径：pkg-config 不会为此拼 SYSROOT
			echo "Libs: $VK_SO"
		else
			echo "Libs: -lvulkan"
		fi
		echo "Cflags:"
	} >"$VKDIR/vulkan.pc"
	echo "  ✓ $VKDIR/vulkan.pc"
	sed 's/^/      /' "$VKDIR/vulkan.pc"
done
echo "  PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"

# ⚠ 不要传 --prefix=$prefix_dir！
#
# media-kit 的约定（见 dav1d.sh 等）是：
#   meson setup …（**不传 --prefix**，用默认 /usr/local）
#   DESTDIR="$prefix_dir" ninja install
# 这样最终装到 $prefix_dir/usr/local/{lib,include}，
# 正好配合 setup_prefix 建的 usr/local 软链。
#
# 之前我传了 --prefix="$prefix_dir" 又叠 DESTDIR，路径变成
#   $prefix_dir$prefix_dir/usr/local/...
# 于是 libplacebo.pc 落到了错误位置，mpv 的
#   Dependency('libplacebo') 报 not found。
meson setup .. \
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

# 安装后校验 libplacebo.pc 是否落在正确位置。
# 由于 setup_prefix 建了 usr/local -> . 软链，两种路径都可能出现，
# 这里都打印出来，方便排查 mpv 的 Dependency('libplacebo')。
echo "=== libplacebo 安装结果 ==="
for f in "$prefix_dir/usr/local/lib/pkgconfig/libplacebo.pc" \
         "$prefix_dir/lib/pkgconfig/libplacebo.pc" \
         "$prefix_dir/usr/local/lib/libplacebo.a" \
         "$prefix_dir/lib/libplacebo.a"; do
	if [ -f "$f" ]; then
		echo "  ✓ $f"
		grep -i 'pl_has_vulkan' "$f" 2>/dev/null || true
	else
		echo "  ✗ $f"
	fi
done

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
