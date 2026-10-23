# PerchPlay v1.1.2 更新说明

> 本版在 v1.1.1 基础上补齐 **iOS 端剩余的可用性问题**，并把 iOS 包名与 Android 统一。

---

## 一、iOS 包名统一（重要）

**`com.vidflow.vidflow` → `com.perchplay.player`**，与 Android 完全一致。

> 若之前在 Apple Developer 后台配过 `com.vidflow.vidflow` 的 App ID / 描述文件，
> 需要重新创建对应的 App ID 和 Provisioning Profile，否则签名会失败。

注意：`com.vidflow/native`、`com.vidflow/pip` 是 Dart↔原生的 MethodChannel 名，
与 Bundle ID 无关，**保持不变**（改了会让所有原生功能失效）。

---

## 二、iOS 从「文件」App 打开视频（修复）

**现象**：在「文件」App 里长按视频 → 共享 → 用 PerchPlay 打开，App 会启动但什么都不播。

**原因**：Info.plist 声明了 `CFBundleDocumentTypes`（视频文件关联），但 AppDelegate
从未实现 `application(_:open:options:)`，`getLaunchVideoUri` / `resolveVideoUri`
在 iOS 上也是空的。

**修复**：
- 实现 `application(_:open:options:)` 接收外部文件
- 把 security-scoped 外部文件复制进 `Documents/Incoming`（回调返回后原 URL 会失效，
  异步长时间播放必须用自己沙盒里的副本）
- 补齐 `getLaunchVideoUri` / `readyForLaunchUri` / `resolveVideoUri` 通道
- 冷启动取一次即清空、热启动通过 `openVideoUri` 回调推送，与 Android 语义一致

---

## 三、iOS 投屏搜不到设备（修复）

**原因**：iOS 14+ 需要「本地网络」权限才能做 SSDP 组播 / 局域网 TCP 探测。之前没有
主动触发，权限弹窗藏在后台探测里，用户拒绝后设备列表恒为空且不再弹窗。

**修复**：进入投屏页先做一次明确的局域网探测，让系统授权框及时出现。

---

## 四、iOS 照片库权限拒绝后 App 不可用（修复）

**原因**：把「照片库权限」误当成了「能否使用 App」的前提。用户拒绝照片库后
`hasVideoPermission` 恒为 false，首页一直显示「需要授权读取本地视频」，
连沙盒 Documents 里的视频都看不到——但 Documents 根本不需要任何权限。

**修复**：iOS 上该标志位恒为 true（可扫描本地文件），照片库权限只影响
「是否导出相册视频」这一件事。

---

## 五、iOS 应用内更新完全失效（修复）

**原因链**：
- `UpdateService` 只找 `.apk` 资产，iOS 上 `apkUrl` 恒为 null → `hasUpdate` 恒为 false
  → 永远显示「已是最新版本」（即使有新版）
- 即使检测到，设置页也会走 `downloadApk` + `installApk` → iOS 上白下载几十 MB 的 APK，
  且 `installApk` 未实现必然失败

**修复**：
- 同时识别 `.ipa` 资产；iOS 上按版本号判断是否更新
- iOS 上不再尝试下载安装，改为复制 Release 链接 + 提示（iOS 沙盒不允许 App 自安装 IPA，
  需 AltStore / SideStore 等工具）

---

## 六、v1.1.1 已包含的内容（iOS 本地文件 + 播放性能）

以下内容在 v1.1.1 中已发布，此处一并说明便于对照：

### iOS 本地文件扫描（新功能）

iOS 是沙盒系统，之前扫描本地文件完全不可用——扫描逻辑硬编码了 Android 的 `/storage/emulated/0`，iOS 上该路径不存在，扫出来永远是空列表。

现在 iOS 通过三条途径获取本地视频：

| 途径 | 说明 | 操作方式 |
|---|---|---|
| **沙盒 Documents 扫描** | 扫描 App 自己的 Documents 目录，配合系统文件共享，该目录会显示在「文件」App →「我的 iPhone」→ PerchPlay | 把视频放进该目录，回 App 点「扫描视频」 |
| **「文件」App 多选导入** | 打开系统文件选择器，可一次选多个视频，自动复制进 App 沙盒 | 文件夹页右上角「导入视频」按钮 |
| **照片库视频扫描** | 读取相册里的视频并导出为本地文件纳入影库 | 首次弹照片库权限，授权后点「扫描视频」 |

同时适配了：
- 文件夹浏览器的 iOS 根目录（不再是 Android 路径）
- 字幕候选目录（iOS 改用沙盒 Documents）
- 空状态/错误状态的按钮与文案按平台切换

> 照片库视频会**导出为真实文件**再入库，而不是直接播系统临时路径——后者在 media_kit 上有「只有音频没画面」的已知问题。

### 播放性能修复

**1. 高码率/大文件起播慢**
- 本地文件 demuxer 缓冲 32MB → 64MB（高码率 4K 单秒数据量就有 6~12MB，32MB 只够 3~5 秒）
- 降低 ffmpeg probe 开销（`analyzeduration=1`、`buffersize=256KB`）
- 本地预读时长 10s → 2s（本地读几乎没有延迟，攒太多反而推迟首帧）

**2. 播放卡顿掉帧**
- `framedrop` 改为 `decoder+vo`：解码/渲染任一侧跟不上都允许丢帧
  （原来只丢渲染侧，解码排队会越积越多，表现为「越播越卡、音画逐渐错位」）
- 显式 `video-sync=audio`，以音频为主时钟
- 关闭运动插值（`interpolation=no`），高开销且手机上收益极小

**3. SDR 视频白白消耗 HDR 开销（重要性能浪费）**

之前对**所有**片源无条件开启色调映射 + `hdr-compute-peak=yes`（逐帧直方图计算），SDR 片源纯属浪费 CPU/GPU，高码率时直接表现为掉帧。现在只在真实 HDR 片源启用；SDR 走 `tone-mapping=clip` 最轻路径。

**4. 解码参数生效时机修正**

`hwdec` / `vd-lavc-threads` 是 mpv 的**每文件选项**，必须在 `open()` **之前**设置。之前放在 open 之后，导致每次首播实际走的是 mpv 默认解码配置——高码率片源因此掉帧。已调整到 open 前。

**5. 刷新/导入慢**
- **修复相册无限重导的 bug**：原实现遇到同名文件就生成 `_1`/`_2` 新名字，导致每次刷新都把整个相册重导一遍、磁盘无限膨胀。改用「资产 ID → 文件名」持久化索引，已导出的直接跳过。
- **照片库导出改为后台异步**：先出 Documents 的列表，照片库导完再增量刷新，不再让用户等整个相册导完。
- **文件导入改 3 路并发复制**（原来逐个串行 await）。
- **扫描时每个文件只做一次 `stat()`**（原来 `length()` + `stat()` 两次 IO）。

### 倍速修复

**1. 高倍速点不动**

之前只调 `setRate`，没有配置 mpv 的音频变速，超过 2x 时音频跟不上会被钳回 2.0——表现就是「点 2.5x/3x/4x 没反应」。

现在配置了 `audio-pitch-correction` + `scaletempo2` 变速滤镜，并且**只在非 1x 时挂滤镜**（1x 下挂滤镜是纯浪费，会拖低流畅度）。播放倍速选项也从 2.0x 上限扩展到 **3.0x**。

**2. 倍速换片后被重置**

`loadVideo` 里原来写死 `speed: defaultSpeed`，用户手动切到 1.5x/2x 后一换片就被打回默认值，看起来像「倍速点了没用」。已改为保留当前倍速。

### 复播黑屏修复

1. **open 前先 `stop()`**：mpv 在已有文件播放状态下直接 open 新文件，旧的视频输出上下文不会立刻释放，新文件首帧常渲染到旧纹理上。
2. **播放页复用判断**：同一视频且队列未变时不再重新 `open`，直接恢复播放。这是从小窗/后台回播放页的关键路径——原来会无条件重载，等于把正在播的视频拆掉重建。

### 其他

- 补齐 `libsmb2` 的 Linux / Windows 预编译库（CI 与本地测试需要），iOS/Android 库此前已具备
- iOS 最低部署目标统一为 **15.0**（Flutter 3.47+ 的硬性要求）

---

## 已知限制

- **iOS 画中画**仍未实现（按钮不显示）
- **照片库视频需先导出**：首次扫描大相册会花一些时间（已做索引去重，第二次起几乎瞬时）
- **iOS 应用内更新**：受 iOS 限制无法自安装，只提供「复制下载链接」引导（用 AltStore 等工具装 IPA）
- 网盘相关限制同前版本（115 大文件、夸克限速、百度/阿里 OAuth）

