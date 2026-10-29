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

DEP="$BS/include/depinfo.sh"
DLS="$BS/include/download-deps.sh"
MPVSH="$BS/scripts/mpv.sh"
LP_VERSION="6.338.2"

echo "=== 1) 复制 libplacebo 构建脚本 ==="
cp "$TOOLS_DIR/libplacebo.sh" "$BS/scripts/libplacebo.sh"
chmod +x "$BS/scripts/libplacebo.sh"

echo "=== 1b) 修复 shaderc.sh 的目录缺失 bug ==="
# 官方 shaderc.sh 最后一步是：
#   cp libs/*/$abi/libshaderc.a "$prefix_dir/lib/libshaderc_combined.a"
# 但 build.sh 的 setup_prefix 只创建 $prefix_dir 本身，**不创建 lib/ 子目录**，
# 导致：
#   cp: cannot create regular file '.../prefix/arm64-v8a/lib/libshaderc_combined.a':
#       No such file or directory
# 这是 media-kit 构建脚本的既有缺陷（平时没人单编 shaderc，所以没暴露）。
# 在脚本开头补一句 mkdir -p 即可。
SHADERC="$BS/scripts/shaderc.sh"
if [ -f "$SHADERC" ]; then
  python3 - "$SHADERC" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p, encoding='utf-8').read()
MARK = '# --- PATCHED-BY-PERCHPLAY: install shaderc to prefix ---'

if MARK not in src:
    # 官方 shaderc.sh 的问题（两处）：
    #  1) 只把 .a 拷到 $prefix_dir/lib，但 $prefix_dir/lib 目录可能不存在
    #     → cp: cannot create ... No such file or directory
    #  2) 头部头文件只拷到 deps/shaderc/include（构建目录内），
    #     **从未**装到 $prefix_dir/include
    #     → libplacebo 编译 spirv_shaderc.c 时报
    #        'shaderc/shaderc.h' file not found
    #  3) 只生成 shaderc_combined.pc，而 libplacebo 的
    #     Dependency('shaderc') 只认 shaderc.pc
    #
    # 与其分别打补丁，不如在脚本**末尾**统一做一次完整安装（幂等、清晰）。
    extra = '''
# --- PATCHED-BY-PERCHPLAY: install shaderc to prefix ---
# 统一把 shaderc 的库 + 头文件 + pkgconfig 装到 prefix，
# 修复官方脚本「头文件只放构建目录、pc 名字不匹配、lib 目录可能不存在」三个问题。
SHADERC_INC="$builddir/include"
[ -d "$SHADERC_INC" ] || SHADERC_INC="$builddir/libs/../include"
# 同时装到 prefix 根和 usr/local 两个位置：
# build.sh 的 setup_prefix 会建 usr/local -> . 的软链做「扁平化」，
# 但 shaderc 步骤执行时该软链不一定在（或 cp -rf 会解引用），
# 前置检查/libplacebo 都按 usr/local 找，所以两边都放一份最保险。
for DEST in "$prefix_dir/include" "$prefix_dir/usr/local/include"; do
	mkdir -p "$DEST"
	if [ -d "$SHADERC_INC/shaderc" ]; then
		cp -rf "$SHADERC_INC/shaderc" "$DEST/" 2>/dev/null || true
	fi
done
if [ -d "$prefix_dir/include/shaderc" ] || [ -d "$prefix_dir/usr/local/include/shaderc" ]; then
	echo "  [patch] 已安装 shaderc 头文件"
else
	echo "  [patch] WARN: 找不到 shaderc 头文件目录 $SHADERC_INC/shaderc"
	ls -la "$builddir/include" 2>/dev/null || true
	ls -la "$builddir/libs/../include" 2>/dev/null || true
fi

LIBSRC=$(ls "$builddir"/libs/*/*/libshaderc.a 2>/dev/null | head -1)
for DESTDIR2 in "$prefix_dir/lib" "$prefix_dir/usr/local/lib"; do
	mkdir -p "$DESTDIR2"
	if [ -n "$LIBSRC" ]; then
		cp -f "$LIBSRC" "$DESTDIR2/libshaderc_combined.a" 2>/dev/null || true
	fi
	# prefix 必须写 /usr/local（相对根路径）：pkg-config 会与
	# PKG_CONFIG_SYSROOT_DIR 拼接，写绝对路径会拼成重复的两段。
	mkdir -p "$DESTDIR2/pkgconfig"
	cat >"$DESTDIR2/pkgconfig/shaderc.pc" <<SHADERCEOF
prefix=/usr/local
exec_prefix=\\${prefix}
libdir=\\${prefix}/lib
includedir=\\${prefix}/include

Name: shaderc
Description: shaderc (NDK bundled, combined static)
Version: 2022.1
Libs: -L\\${libdir} -lshaderc_combined -lc++
Cflags: -I\\${includedir}
SHADERCEOF
done
echo "  [patch] 已生成 shaderc.pc（lib + usr/local/lib 两份）"
'''
    src = src.rstrip() + '\n' + extra
    open(p, 'w', encoding='utf-8').write(src)
    print('  shaderc.sh 已追加完整安装逻辑')
else:
    print('  shaderc.sh 已修补过，跳过')
PYEOF
fi

echo "=== 1c) 修复 autoconf 脚本的交叉编译三元组 bug ==="
# 官方 libxml2.sh 用 --host=$ndk_triple，而 build.sh 里：
#   ndk_triple=aarch64-linux-android        （**没有** API level 后缀）
#   cc_triple=aarch64-linux-android21       （有 API level，但它不是 export 的）
# autoconf 靠三元组末尾的版本号识别交叉编译；缺了就报：
#   configure: error: cannot run C compiled programs.
#   If you meant to cross compile, use `--host'.
# 结果 ffmpeg 找不到 dav1d/libxml2，整个构建中断。
#
# 注意 cc_triple 是 build.sh 里的 local 变量，子脚本拿不到；
# 但 build.sh 导出了 CC=$cc_triple-clang，所以要的答案在 $CC 里：
#   aarch64-linux-android21-clang  → 去掉 -clang 就是完整三元组。
XML2="$BS/scripts/libxml2.sh"
if [ -f "$XML2" ] && grep -q -- '--host=\$ndk_triple' "$XML2"; then
  sed -i 's/--host=\$ndk_triple/--host=${CC%-clang}/' "$XML2"
  echo "  已改为 --host=\${CC%-clang}"
fi
grep -n 'host=' "$XML2" || true

echo "=== 1d) 同理修正其它用 --host=\$ndk_triple 的脚本 ==="
for f in "$BS"/scripts/*.sh; do
  if grep -q -- '--host=\$ndk_triple' "$f" 2>/dev/null; then
    sed -i 's/--host=\$ndk_triple/--host=${CC%-clang}/' "$f"
    echo "  修正: $(basename "$f")"
  fi
done

echo "=== 1e) 对齐 NDK 版本（官方硬编码 25.2，预装环境只有 27+）==="
# 官方 build.yaml 用软链接的方式复用 Actions 预装 SDK，但 depinfo.sh 里
# 硬编码 v_ndk=25.2.9519653，而 ubuntu-22.04 runner 预装的 NDK 是
# 27.3.13750724 / 29.0 / 30.0 —— 没有 25.2。
# path.sh 会拼出 ndk/25.2.9519653/toolchains/... → 不存在 →
#   make: aarch64-linux-android21-clang: No such file or directory
# 所以把 v_ndk 改成预装里实际存在的版本。
# 优先 27.3（与 25 最接近、且 ndk-build 兼容 shaderc 的路径结构）。
NDK_DIR=""
if [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}/ndk" ]; then
  for pref in 27.3.13750724 27.2.12479018 26.3.11579264 26.1.10909125 25.2.9519653; do
    if [ -d "${ANDROID_HOME}/ndk/${pref}" ]; then NDK_DIR="$pref"; break; fi
  done
  # 都对不上就取目录里任意一个
  if [ -z "$NDK_DIR" ]; then
    NDK_DIR=$(ls "${ANDROID_HOME}/ndk" 2>/dev/null | head -1)
  fi
fi

if [ -n "$NDK_DIR" ]; then
  sed -i "s/^v_ndk=.*/v_ndk=${NDK_DIR}/" "$DEP"
  echo "  v_ndk -> ${NDK_DIR}"
else
  echo "  ⚠️ 未探测到 NDK，保留原值（可能失败）"
fi
grep -n '^v_ndk=' "$DEP" || true

echo "=== 1f) 修 mbedtls 的 NEON 兼容（NDK 27 / clang 18）==="
# NDK 27 自带 clang 18，其 arm_neon.h 对 always_inline 函数要求显式
# target feature。mbedtls 3.4 的 aesce 代码没加，于是编译报：
#   arm_neon.h:62502: error: always_inline function 'vget_high_p64'
#   requires target feature 'sha3', but would be inlined into function
# 给 mbedtls 显式补 -march=armv8-a+crypto+sha3 即可。
MBED="$BS/scripts/mbedtls.sh"
if [ -f "$MBED" ] && ! grep -q 'armv8-a' "$MBED"; then
  sed -i 's/make CFLAGS=-fPIC CXXFLAGS=-fPIC/make CFLAGS="-fPIC -march=armv8-a+crypto+sha3" CXXFLAGS="-fPIC -march=armv8-a+crypto+sha3"/g' "$MBED"
  echo "  已给 mbedtls 加 -march=armv8-a+crypto+sha3"
fi
grep -n 'march=' "$MBED" || true

echo "=== 1g) 修 pkg-config 路径（dav1d/libxml2 找不到的根因）==="
# path.sh 里是：
#   export PKG_CONFIG_SYSROOT_DIR=$prefix_dir
#   export PKG_CONFIG_LIBDIR=$PKG_CONFIG_SYSROOT_DIR/lib/pkgconfig
#
# 但 setup_prefix 做了扁平化软链：
#   ln -s . "$prefix_dir/usr"
#   ln -s . "$prefix_dir/local"
# 于是依赖实际装在 $prefix_dir/usr/local/lib/pkgconfig，
# 而 PKG_CONFIG_LIBDIR 指向 $prefix_dir/lib/pkgconfig ——
# 两者靠软链其实是同一目录，但 **PKG_CONFIG_SYSROOT_DIR 会让 pkg-config
# 在 .pc 里的 -L 路径前再拼一次 sysroot**，拼成 $prefix_dir/$prefix_dir/lib，
# 于是 ffmpeg 的 configure 判定 "dav1d >= 0.5.0 not found"。
#
# 修法：SYSROOT 置空（交叉编译时 prefix 已经是绝对沙盒路径，不需要再拼），
# LIBDIR 直接指向真实存在的 usr/local/lib/pkgconfig。
PATHSH="$BS/include/path.sh"
if [ -f "$PATHSH" ] && ! grep -q 'PKG_CONFIG_FIXED_BY_PATCH' "$PATHSH"; then
  python3 - "$PATHSH" <<'PYEOF'
import sys, re
p = sys.argv[1]
src = open(p, encoding='utf-8').read()
# 只改 LIBDIR，**不动 SYSROOT**：
#   SYSROOT 保留是对的（交叉编译时 .pc 里的相对路径需要它来定位），
#   问题只在 LIBDIR 少了一段 usr/local。
#   加上 $prefix_dir/usr/local/lib/pkgconfig 后，pkg-config 能扫到
#   dav1d.pc / libxml-2.0.pc / libplacebo.pc 等实际产物。
src = re.sub(
    r'\s*export\s+PKG_CONFIG_LIBDIR=("[^"]*"|\S*)',
    '\n\texport PKG_CONFIG_LIBDIR="$prefix_dir/usr/local/lib/pkgconfig:$prefix_dir/lib/pkgconfig"',
    src)
open(p, 'w', encoding='utf-8').write(src)
print('  path.sh 的 PKG_CONFIG_LIBDIR 已扩大搜索路径')
PYEOF
fi
grep -n 'PKG_CONFIG' "$PATHSH" || true

echo "=== 1h) 生成 vulkan.pc（NDK 只带 header，不带 pkg-config 文件）==="
# mpv 的 meson.build:1269 是：
#   vulkan = dependency('vulkan', version: '>= 1.1.70', required: vulkan_opt)
# 而 Android NDK 只提供 vulkan/vulkan.h（在 sysroot 里），**没有 vulkan.pc**，
# 于是报：
#   ld.lld: error: unable to find library -lvulkan
#   ERROR: Dependency "vulkan" not found (tried pkg-config and system)
#
# Android 的 libvulkan.so 是系统库（由设备/模拟器提供），链接时用
# -lvulkan 由 NDK 的 toolchain 解析到 sysroot 的存根库。
#
# ⚠ 这里**只往构建仓库里装一份生成脚本**，不在 patch 阶段直接生成
# vulkan.pc —— patch 执行时 build.sh 还没跑，$prefix_dir 还不存在
# （会报 "prefix_dir: unbound variable"）。
# 由 libplacebo.sh 在真正编译前生成（那时 prefix 已就绪）。
echo "=== 1h) 登记 vulkan.pc 的生成逻辑（实际生成在 libplacebo.sh 里）==="
echo "  说明：patch 阶段 prefix_dir 不存在，改为在 libplacebo.sh 编译前生成"

echo "=== 2) depinfo.sh：版本号 + 依赖关系 ==="
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
sed -i 's/-Dvulkan=disabled/-Dvulkan=enabled/' "$MPVSH"
sed -i 's/-Dlibplacebo=disabled/-Dlibplacebo=enabled/' "$MPVSH"
# 先清掉可能存在的 spirv-cross=enabled（早期版本误加的）。
#
# media-kit 的依赖树里**没有** spirv-cross 这个包，一旦开启，mpv 的
#   meson.build:978  Dependency('spirv-cross-c-shared')
# 就会硬失败。而 libplacebo 用 shaderc 就能把 GLSL 编成 SPIR-V，
# 完全不需要 spirv-cross。
sed -i 's/^[[:space:]]*-Dspirv-cross=enabled[[:space:]]*\\\{0,1\}$//' "$MPVSH"
sed -i 's/[[:space:]]*-Dspirv-cross=enabled//g' "$MPVSH"
# shaderc：libplacebo 运行时把 GLSL 编成 SPIR-V（hdr-toys 需要）
if ! grep -q 'Dshaderc=enabled' "$MPVSH"; then
  sed -i 's/-Dvulkan=enabled/-Dvulkan=enabled \\\n\t-Dshaderc=enabled/' "$MPVSH"
fi
# plain-gl：libmpv（非 cplayer）场景下 gpu-next 需要它才能建上下文
if ! grep -q 'Dplain-gl=enabled' "$MPVSH"; then
  sed -i 's/-Dshaderc=enabled/-Dplain-gl=enabled \\\n\t-Dshaderc=enabled/' "$MPVSH"
fi

echo ""
echo "=== 5) mpv 源码 patch：补 JVM 注册（mediacodec / vo=gpu 必需）==="
#
# ## 为什么必须打这个 patch
#
# 实测日志（v1.1.8 build 121）：
#     [mpv/ffmpeg/video] hevc_mediacodec: No Java virtual machine has been registered
#     [mpv/vo/gpu/android] No Java virtual machine has been registered
#     [mpv/vo/gpu] Failed initializing any suitable GPU context!
#
# 后果：vo=gpu 完全建不起来 → 只能用兜底 vo；mediacodec 硬解也失效
# → 只能软解。表现就是「部分视频有画面、部分没有」，4K HDR 更糟。
#
# ## 根因（已核对 ffmpeg / mpv 源码）
#
# mpv 的 osdep/jni.c：
#     java_vm = av_jni_get_java_vm(NULL);
#     if (!java_vm) mp_err(log, "No Java virtual machine has been registered\n");
#
# ffmpeg 的 libavcodec/jni.c：
#     #if CONFIG_JNI
#     int av_jni_set_java_vm(void *vm, ...) { ... }   ← 真实现
#     #else
#     void *av_jni_get_java_vm(...) { return NULL; }  ← 永远 NULL
#     #endif
#
# ffmpeg 用 --enable-jni 打开 CONFIG_JNI（官方 full flavor 已有）。
# 但**静态链接时 av_jni_set_java_vm 符号不可见**，所以必须由 libmpv
# 导出一个转发函数。
#
# ## 谁来调用它 —— 用 JNI_OnLoad 自动注册（无需 Java 侧配合）
#
# JVM 在 `System.loadLibrary("mpv")` 时会自动调用库里的
# `JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved)`，并把
# **JavaVM\* 直接传进来**。所以只要 libmpv 导出 JNI_OnLoad，
# 就能在那一刻把 vm 注册给 ffmpeg —— Java/Kotlin 侧零改动，
# Dart 侧也零改动。
#
# 这比「Java 侧反射拿指针再传过来」可靠得多：Kotlin 拿不到 C 指针。
#
# media-kit 官方仓库用 patches/mpv/mpv_lavc_set_java_vm.patch 解决，
# 我们自建 libmpv 时漏了。这里补上，并**主动应用**（官方 build.sh
# 不会自动跑 patch.sh，那是 CI 的单独步骤）。
MPV_DEPS="$BS/deps/mpv"
if [ ! -d "$MPV_DEPS" ]; then
  echo "  [patch] ⚠ mpv 源码目录不存在（$MPV_DEPS），跳过 JVM patch"
  echo "  [patch]   这会导致 mediacodec / vo=gpu 不可用"
  FAIL_JVM=1
else
  python3 - "$MPV_DEPS" <<'PYEOF'
import sys, os, re

root = sys.argv[1]

# ── 1) client.h：声明 mpv_lavc_set_java_vm ──
h = os.path.join(root, 'libmpv', 'client.h')
src = open(h, encoding='utf-8').read()
MARK = 'mpv_lavc_set_java_vm'
if MARK not in src:
    anchor = 'MPV_EXPORT void mpv_wakeup(mpv_handle *ctx);'
    if anchor not in src:
        print('   ❌ client.h 里找不到 mpv_wakeup 声明')
        sys.exit(1)
    decl = anchor + '''

/**
 * Calls av_jni_set_java_vm() with the given JavaVM*.
 *
 * av_jni_set_java_vm() is not visible when statically linking libavcodec,
 * so libmpv re-exports it here. Must be called from Java after
 * System.loadLibrary("mpv") for mediacodec / vo=gpu to work.
 */
MPV_EXPORT int mpv_lavc_set_java_vm(void *vm);'''
    src = src.replace(anchor, decl, 1)
    open(h, 'w', encoding='utf-8').write(src)
    print('   ✓ client.h 已加声明')
else:
    print('   · client.h 已有声明')

# ── 2) player/client.c：实现 mpv_lavc_set_java_vm + JNI_OnLoad ──
c = os.path.join(root, 'player', 'client.c')
src = open(c, encoding='utf-8').read()
if 'mpv_lavc_set_java_vm' not in src:
    # 加 include
    if 'libavcodec/jni.h' not in src:
        for anchor in ('#include "common/common.h"',
                       '#include <assert.h>'):
            if anchor in src:
                src = src.replace(
                    anchor, '#include <libavcodec/jni.h>\n\n' + anchor, 1)
                break
        else:
            print('   ❌ client.c 里找不到合适的 include 插入点')
            sys.exit(1)
    # 加实现（放在 mpv_wakeup 之后）
    m = re.search(r'(void mpv_wakeup\(mpv_handle \*ctx\)\s*\{.*?\n\}\n)',
                  src, re.S)
    if not m:
        print('   ❌ client.c 里找不到 mpv_wakeup 实现')
        sys.exit(1)
    impl = m.group(1) + '''
int mpv_lavc_set_java_vm(void *vm) {
    return av_jni_set_java_vm(vm, NULL);
}

/*
 * JNI_OnLoad：JVM 在 System.loadLibrary("mpv") 时自动调用，
 * 并把 JavaVM* 直接传进来。这里立刻注册给 ffmpeg ——
 * 否则 mediacodec 与 vo=gpu 都会报
 *   "No Java virtual machine has been registered"
 * 而完全不可用（v1.1.8 build 121 实测日志）。
 *
 * 用弱符号避免在非 Android 平台链接失败。
 */
#if defined(__ANDROID__)
#include <jni.h>
__attribute__((visibility("default")))
jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    mpv_lavc_set_java_vm((void *)vm);
    return JNI_VERSION_1_6;
}
#endif
'''
    src = src[:m.start(1)] + impl + src[m.end(1):]
    open(c, 'w', encoding='utf-8').write(src)
    print('   ✓ client.c 已加 mpv_lavc_set_java_vm + JNI_OnLoad')
else:
    print('   · client.c 已打过 patch')
PYEOF
  if [ $? -ne 0 ]; then
    echo "  [patch] ❌ JVM patch 应用失败"
    FAIL_JVM=1
  else
    echo "  [patch] ✅ JVM 注册 patch 已应用"
  fi
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

# JVM 注册 patch 校验：缺了会导致 mediacodec / vo=gpu 全废
echo "--- JVM patch ---"
if [ -d "$BS/deps/mpv" ]; then
  grep -q 'JNI_OnLoad' "$BS/deps/mpv/player/client.c" \
    && echo "  ✓ JNI_OnLoad 已注入" \
    || { echo "❌ JNI_OnLoad 未注入（mediacodec / vo=gpu 会失效）"; FAIL=1; }
  grep -q 'mpv_lavc_set_java_vm' "$BS/deps/mpv/libmpv/client.h" \
    && echo "  ✓ mpv_lavc_set_java_vm 已声明" \
    || { echo "❌ client.h 缺声明"; FAIL=1; }
else
  echo "  ⚠ mpv 源码尚未下载，无法校验（构建阶段会应用）"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "✅ patch 完成"
else
  echo "❌ patch 有缺失"
  exit 1
fi
