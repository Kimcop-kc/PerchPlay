#!/usr/bin/env python3
"""
把自建的 libmpv JAR 注入 media_kit_libs_android_video。

背景
────
media_kit_libs_android_video 的 android/build.gradle 里有个
downloadDependencies 任务，会从 GitHub Release 下载官方预编译的
full-*.jar（内含 libmpv.so），并在 assemble 前执行。官方 JAR 的
libmpv 是**没有 libplacebo/gpu-next** 的，所以不能直接用。

做法
────
不改任务逻辑，只替换 filesToDownload 这个列表：
把 4 个 GitHub URL 换成本地文件的 file:// URL，并把 md5 换成
我们 JAR 的实际值。这样：
  - 仍然走官方那套「校验 → 拷贝到 buildDir/output」流程
  - 但拿到的就是我们自建的 libmpv.so
好处是改动面最小，且保留了 MD5 校验（自建 JAR 若损坏会立刻报错）。

用法
────
  patch_media_kit_jar.py <jar路径> <abi>

  abi 例：arm64-v8a / armeabi-v7a / x86_64

退出码
──────
  0  成功（或已打过补丁，幂等）
  1  失败
"""
import hashlib
import os
import re
import sys

MARK = "PATCHED-BY-PERCHPLAY-LIBPLACEBO"


def find_gradle() -> str:
    """定位 pub cache 里的 media_kit_libs_android_video 的 build.gradle。"""
    candidates = []

    pub_cache = os.environ.get("PUB_CACHE")
    roots = []
    if pub_cache:
        roots.append(pub_cache)
    roots.append(os.path.expanduser("~/.pub-cache"))
    roots.append(os.path.expanduser("~/AppData/Local/Pub/Cache"))

    for root in roots:
        hosted = os.path.join(root, "hosted", "pub.dev")
        if not os.path.isdir(hosted):
            continue
        for name in os.listdir(hosted):
            if not name.startswith("media_kit_libs_android_video-"):
                continue
            g = os.path.join(hosted, name, "android", "build.gradle")
            if os.path.isfile(g):
                candidates.append(g)

    if not candidates:
        raise SystemExit(
            "❌ 在 pub cache 里找不到 media_kit_libs_android_video/android/build.gradle\n"
            "   先执行 flutter pub get 再跑本脚本。\n"
            f"   已查找: {roots}"
        )

    # 有多个版本时取版本号最大的
    def ver(p):
        m = re.search(r"media_kit_libs_android_video-([\d.]+)", p)
        return tuple(int(x) for x in m.group(1).split(".")) if m else (0,)

    candidates.sort(key=ver)
    return candidates[-1]


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    jar = os.path.abspath(sys.argv[1])
    abi = sys.argv[2]

    if not os.path.isfile(jar):
        print(f"❌ JAR 不存在: {jar}")
        return 1

    with open(jar, "rb") as f:
        md5 = hashlib.md5(f.read()).hexdigest()
    size_mb = os.path.getsize(jar) / 1048576
    print(f"JAR: {jar}")
    print(f"     {size_mb:.1f} MB  md5={md5}")

    gradle = find_gradle()
    print(f"目标: {gradle}")

    src = open(gradle, encoding="utf-8").read()

    if MARK in src:
        print("✓ 已打过补丁，跳过（幂等）")
        return 0

    # file:// URL：Gradle 里 new URL(...).openStream() 支持 file 协议
    file_url = "file://" + jar.replace("\\", "/")

    new_block = (
        f"        // {MARK}\n"
        f"        // 官方 JAR 的 libmpv 不含 libplacebo/gpu-next，改用自建版本。\n"
        f"        // 只保留实际构建的 ABI（{abi}），其余不下载。\n"
        f"        def filesToDownload = [\n"
        f'            ["url": "{file_url}", '
        f'"md5": "{md5}", '
        f'"destination": file("$buildDir/libplacebo/full-{abi}.jar")]\n'
        f"        ]\n"
    )

    # 替换 `def filesToDownload = [ ... ]` 整块。
    # 用非贪婪匹配到第一个只含可选空白的 `]`（该列表的元素都在同一行内）。
    pattern = re.compile(
        r"[ \t]*def\s+filesToDownload\s*=\s*\[.*?\n[ \t]*\]\n",
        re.DOTALL,
    )
    new_src, n = pattern.subn(new_block, src, count=1)
    if n != 1:
        print("❌ 没能定位 filesToDownload 列表，改用逐项替换")
        # 兜底：把每个 url/md5 都换掉（只保留第一个 effective）
        print(src[:2000])
        return 1

    open(gradle, "w", encoding="utf-8").write(new_src)
    print("✓ 已替换 filesToDownload")

    # 打印改后的区块，便于 CI 日志核对
    for line in new_src.split("\n"):
        if MARK in line or "filesToDownload" in line or "file://" in line:
            print("   " + line.strip()[:160])

    return 0


if __name__ == "__main__":
    sys.exit(main())
