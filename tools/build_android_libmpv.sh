#!/bin/bash -e
# ─────────────────────────────────────────────────────────────────────
# 构建带 libplacebo (gpu-next) 的 Android libmpv JAR
#
# 用法：
#   build_android_libmpv.sh <构建仓库路径> [架构]
#     架构默认 arm64，可选 arm64 | armv7l
#
# 前置条件（由 CI 的 workflow 负责）：
#   - 构建仓库已 clone 到 <构建仓库路径>
#   - tools/patch_libplacebo.sh 已执行过（patch 已应用）
#   - 构建工具（meson/ninja/cmake/autotools）已安装
#   - ANDROID_HOME 已设置，且 buildscripts/sdk/android-sdk-linux 软链已建好
#   - 依赖源码已下载（download-deps.sh）
#
# 产物：
#   <构建仓库>/buildscripts/artifacts/libplacebo/full-<abi>.jar
#
# ── 为什么这么做 ──
# media-kit 官方 JAR（default-<abi>.jar）里有两个 so：
#   lib/<abi>/libmpv.so                      ← 我们要换掉的
#   lib/<abi>/libmediakitandroidhelper.so    ← media_kit 的 JNI 辅助库
#
# libmediakitandroidhelper.so 与 ffmpeg flavor 无关，是纯 JNI 桥接，
# 官方那份可以直接复用。所以最省事、最可靠的做法是：
#   1. 下载官方 JAR
#   2. 只把 libmpv.so 换成我们编译的
#   3. 重新打包
# 相比「自己跑 gradle 编 media-kit-android-helper」，这样不需要网络
# 拉 gradle 依赖、不需要 JDK/Kotlin 编译，失败点少得多。
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

BUILD_REPO="${1:?用法: $0 <构建仓库路径> [架构]}"
ARCH="${2:-arm64}"
BS="$BUILD_REPO/buildscripts"

[ -d "$BS" ] || { echo "❌ 找不到 $BS"; exit 1; }

case "$ARCH" in
	arm64)   ABI=arm64-v8a ;;
	armv7l)  ABI=armeabi-v7a ;;
	x86_64)  ABI=x86_64 ;;
	*) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

# 官方 JAR 的版本。media_kit_libs_android_video 1.3.8 用的就是 v1.1.7。
OFFICIAL_VER="${OFFICIAL_JAR_VER:-v1.1.7}"
OFFICIAL_URL="https://github.com/media-kit/libmpv-android-video-build/releases/download/${OFFICIAL_VER}/default-${ABI}.jar"

echo "════════════════════════════════════════════"
echo " 构建 libplacebo 版 libmpv"
echo "   架构: $ARCH  (ABI: $ABI)"
echo "   仓库: $BUILD_REPO"
echo "   官方 JAR: $OFFICIAL_VER"
echo "════════════════════════════════════════════"

cd "$BS"

# ── 1) 编译 ──────────────────────────────────────────────────────────
# 注意：bundle_full.sh 是 ./build.sh（不带参数，编所有架构）。
# 这里只编单架构，省时间。
echo ""
echo "▶ [1/6] 编译（shaderc → libplacebo → 其余 → mpv）"
chmod +x build.sh
./build.sh --arch "$ARCH" mpv

LIBMPV_SRC="$BS/prefix/$ABI/usr/local/lib/libmpv.so"
[ -f "$LIBMPV_SRC" ] || LIBMPV_SRC="$BS/prefix/$ABI/lib/libmpv.so"
if [ ! -f "$LIBMPV_SRC" ]; then
	echo "❌ 没有产出 libmpv.so"
	find "$BS/prefix" -name 'libmpv.so' 2>/dev/null || true
	exit 1
fi
echo "   ✓ $LIBMPV_SRC  ($(du -h "$LIBMPV_SRC" | cut -f1))"

# ── 2) 校验关键能力 ──────────────────────────────────────────────────
# 这是本工程的**核心目的**：确认 gpu-next/libplacebo 真的编进去了。
# 缺这个校验，后面打包出来是个「看起来正常但用不了 HDR」的库。
echo ""
echo "▶ [2/6] 校验 libplacebo / vulkan / shaderc"
PC="$BS/prefix/$ABI/usr/local/lib/pkgconfig/libplacebo.pc"
[ -f "$PC" ] || PC="$BS/prefix/$ABI/lib/pkgconfig/libplacebo.pc"
if [ -f "$PC" ]; then
	grep -q 'pl_has_vulkan=1' "$PC" || { echo "❌ pl_has_vulkan != 1"; cat "$PC"; exit 1; }
	grep -q 'pl_has_shaderc=1' "$PC" || { echo "❌ pl_has_shaderc != 1"; cat "$PC"; exit 1; }
	echo "   ✓ libplacebo: pl_has_vulkan=1, pl_has_shaderc=1"
else
	echo "⚠ 找不到 libplacebo.pc，跳过校验"
fi

if readelf -d "$LIBMPV_SRC" 2>/dev/null | grep -q 'libvulkan.so'; then
	echo "   ✓ libmpv.so 已链接 libvulkan.so"
else
	echo "❌ libmpv.so 未链接 libvulkan.so，gpu-next 无法工作"
	readelf -d "$LIBMPV_SRC" | grep NEEDED || true
	exit 1
fi

# ── 3) strip ─────────────────────────────────────────────────────────
# 官方 bundle_full.sh 也是先 strip 再打包。
# 我们的 libmpv.so 未 strip 时约 64MB，strip 后大幅缩小。
# 先另存一份带符号的，方便以后定位崩溃。
echo ""
echo "▶ [3/6] strip 符号"
LLVM_STRIP=$(find "${ANDROID_HOME:-/usr/local/lib/android/sdk}/ndk" \
	-name 'llvm-strip' -type f 2>/dev/null | head -1)
OUTDIR="$BS/artifacts/libplacebo"
mkdir -p "$OUTDIR"
if [ -n "$LLVM_STRIP" ]; then
	echo "   使用: $LLVM_STRIP"
	cp -f "$LIBMPV_SRC" "$OUTDIR/libmpv-$ABI-unstripped.so"
	BEFORE=$(stat -c%s "$LIBMPV_SRC")
	"$LLVM_STRIP" --strip-all "$LIBMPV_SRC"
	AFTER=$(stat -c%s "$LIBMPV_SRC")
	echo "   ✓ strip: $((BEFORE/1048576))MB → $((AFTER/1048576))MB"
else
	echo "   ⚠ 找不到 llvm-strip，保留未 strip 版本（体积会大 3~5 倍）"
fi

# strip 之后再确认一次 vulkan 依赖还在（避免 strip 误删）
readelf -d "$LIBMPV_SRC" | grep -q 'libvulkan.so' \
	|| { echo "❌ strip 后 libvulkan.so 依赖丢失"; exit 1; }
echo "   ✓ strip 后 vulkan 依赖仍在"

# ── 4) 下载官方 JAR ──────────────────────────────────────────────────
echo ""
echo "▶ [4/6] 下载官方 JAR（复用其中的 libmediakitandroidhelper.so）"
OFFICIAL_JAR="$OUTDIR/official-$ABI.jar"
if [ ! -f "$OFFICIAL_JAR" ]; then
	echo "   下载: $OFFICIAL_URL"
	curl -fSL --retry 3 --retry-delay 3 -o "$OFFICIAL_JAR" "$OFFICIAL_URL"
fi
test -s "$OFFICIAL_JAR" || { echo "❌ 官方 JAR 下载失败"; exit 1; }
echo "   ✓ $(du -h "$OFFICIAL_JAR" | cut -f1)"
echo "   内容："
unzip -l "$OFFICIAL_JAR" | sed 's/^/     /'

# ── 5) 替换 libmpv.so ────────────────────────────────────────────────
echo ""
echo "▶ [5/6] 替换 libmpv.so"
WORK="$OUTDIR/_jarwork-$ABI"
rm -rf "$WORK"
mkdir -p "$WORK"
unzip -oq "$OFFICIAL_JAR" -d "$WORK"

DEST_DIR="$WORK/lib/$ABI"
[ -d "$DEST_DIR" ] || { echo "❌ 官方 JAR 里没有 lib/$ABI"; ls -R "$WORK" | head -30; exit 1; }

echo "   替换前:"
ls -lh "$DEST_DIR" | sed 's/^/     /'
cp -f "$LIBMPV_SRC" "$DEST_DIR/libmpv.so"
echo "   替换后:"
ls -lh "$DEST_DIR" | sed 's/^/     /'

# ── 6) 重新打包 ──────────────────────────────────────────────────────
echo ""
echo "▶ [6/6] 打包 JAR"
JAR="$OUTDIR/full-$ABI.jar"
rm -f "$JAR"
cd "$WORK"
zip -qr "$JAR" "lib/$ABI"
cd "$BS"

# 清理中间产物，避免污染 artifact
rm -rf "$WORK" "$OFFICIAL_JAR"

echo ""
echo "════════════════════════════════════════════"
echo " ✅ 完成"
echo "   JAR: $JAR  ($(du -h "$JAR" | cut -f1))"
echo "   对比官方 JAR: $(du -h "$OUTDIR/libmpv-$ABI-unstripped.so" 2>/dev/null | cut -f1) (未 strip 的 so)"
echo ""
echo "   内容:"
unzip -l "$JAR" | sed 's/^/     /'
echo "════════════════════════════════════════════"
