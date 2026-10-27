# PerchPlay v1.1.5 更新说明

> 本版修复 **退出播放页进度丢失** 与 **投屏后本地仍在出声** 两个问题。
> 下方保留 v1.1.4 / v1.1.3 / v1.1.2 / v1.1.1 的完整改动记录。

---

## 本版（v1.1.5）改动

### 一、退出播放页后播放进度丢失（修复）

**现象**：看完视频退出播放页，再进来续播位置不对；诊断日志里能看到：

```
[Player] dispose 保存进度失败: Bad state: Cannot use "ref" after the widget was disposed.
```

**根因**：`dispose()` 里调 `ref.read(playerProvider.notifier).saveProgress()`，
但 Riverpod 在 `dispose` 阶段 `ref` 已经失效，异常被 `catch` 吞掉 ——
**进度根本没写进数据库**。

**修复**：在 `initState` 就把 `PlayerNotifier` 与播放版本号的 notifier 引用
缓存下来，`dispose` 直接用缓存引用，不再碰 `ref`。

### 二、投屏后手机和电视同时出声（修复）

**现象**：投屏成功后，手机扬声器还在放，电视也在放，两条进度各自走。

**根因**：`_castCurrentTo` 调完 `castLocalFile` 就结束了，
**没有暂停本地播放**。

**修复**：投屏成功后，若本地正在播放则自动暂停。

---

## 历史版本改动（v1.1.4）

> 本版修复 **NAS / 网盘** 两类问题：WebDAV 目录点不开、网盘没有外挂字幕。

---

## 本版（v1.1.4）改动

### 一、NAS（WebDAV）：目录和视频点不开（重要修复）

**现象**：点 NAS 里的文件夹（比如「Obsidian」）完全没反应，日志是：

```
[NAS-UI] 点击「Obsidian」 dir=false video=false
```

既不是目录也不是视频，两个分支都不进，所以什么都没发生。

**根因**：WebDAV 的 `multistatus` 响应解析正则**硬编码了 `<D:xxx>` 前缀**：

```dart
RegExp(r'<D:collection/>')
RegExp(r'<D:href>(.*?)</D:href>')
```

RFC 4918 允许任意命名空间前缀（`D:` / `d:` / `ns0:` / 无前缀），
返回小写 `d:` 或无前缀的服务器（群晖、部分 WebDAV 网关）就会：

- `isDirectory` 恒为 false → **目录点不开**
- `displayname` 取不到 → 文件名退化，`isVideo` 也判不出 → **视频点不开**

**修复**：所有标签正则改为「任意前缀（含无前缀）+ 不区分大小写」，
`collection` 同时兼容 `<D:collection/>` 和 `<D:collection></D:collection>` 两种写法。

新增 12 项回归测试覆盖大写/小写/无前缀/`ns0`/非自闭合等变体。

> iPad 上「播放不了视频 + NAS 点不开」是同一个根因。

### 二、网盘：自动加载同目录外挂字幕（新功能）

**现象**：网盘（夸克/百度/115/阿里）里的视频永远没有外挂字幕，
本地视频却有。

**根因**：本地视频靠 `Directory(dirname).list()` 扫同目录，但网盘只有
HTTP 直链、没有本地目录；`player_provider` 里甚至直接
`if (isRemotePath) return` 跳过了网盘的字幕匹配。

**修复**：新增 `CloudSubtitleService`，走网盘 API 完成整条链路：

1. 播放时把**账号 id + 目录 id + 文件名**带进播放页
2. 播放页后台调 `listDirectory` 列视频所在目录
3. 按「与视频同名 / 同名前缀」筛选 `.srt` / `.ass` / `.vtt` 等
4. `getDownloadUrl` 取直链，下载到本地缓存（单文件 2MB 上限、最多 5 个）
5. 加入字幕候选列表并**自动挂载**第一个

整个过程在后台执行，**不阻塞视频开播**；已有字幕（用户自选/内嵌）不会被覆盖。

> 说明：mpv 只能读本地文件，所以网盘字幕必须先下载到缓存再挂载。

---

## 历史版本改动（v1.1.3）

> 本版主要修复 **iOS 端 DTS / 杜比全景声音轨无声**（libmpv 换 full 版），
> 并压缩播放页底部控制栏占位。

---

## 本版（v1.1.3）改动

### 一、iOS：DTS / 杜比全景声音轨终于有声音了（重要修复）

**现象**：iPad / iPhone 播放含 DTS、DTS-HD、杜比全景声（TrueHD / EAC3）音轨的
mkv 时，**有画面但没声音**。日志里能看到：

```
Failed to initialize a decoder for codec 'dts'.
```

**根因**：media_kit 为了压缩包体，iOS 默认用的是 libmpv 的 **default（精简版）**
变体，DTS / PGS 字幕等解码器被编译时裁掉了（[media-kit#359](https://github.com/media-kit/media-kit/issues/359)）。

**修复**：构建时把 libmpv 从 `default` 换成 `full` 完整版。

同时修掉了一个隐藏问题：`make` 的产物文件名不区分 default/full，只要缓存里
残留旧版就会判定「无事可做」直接跳过下载——上一版切换因此**实际没生效**
（IPA 体积没变）。现在会先清空缓存再强制重新下载。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| Avcodec（解码器所在库） | 3.52 MB | **6.76 MB** |
| DTS / 杜比全景声 / PGS 字幕 | ❌ 缺失 | ✅ 完整 |
| IPA 体积 | 16.8 MB | 19 MB |

> 说明：杜比视界 / HDR10 的**视频**解码本来就支持（default 版就有 HEVC），
> 这次补的是**音频**解码。

### 二、播放页底部控制栏占位过高（UI 修复）

**现象**：进度条和时间行占位太高，和按钮之间有大片空白。

**根因**：
- 进度条 `GlassSlider` 高度 = 轨道(3) + 圆点直径(14) + **24 的固定留白**
- 时间文字用默认行高（约 1.2~1.4），额外撑出 3~5px

**修复**：

| 项 | 改前 | 改后 |
|---|---|---|
| 进度条高度 | 41px | **21px** |
| 时间文字行高 | 默认 1.2~1.4 | **1.0** |
| 进度条→时间行间距 | 4 | **2** |
| 时间行→按钮行间距 | 6 | **4** |

整块高度约 **67px → 38px**，正好容下控件。
（触摸命中区由 GestureDetector 覆盖整个区域，不靠撑高实现，不影响可点性。）

**进一步调整（实测后继续收）**：
- 整块再向下移动 12px（吃掉底部 padding 里多余的 8px 余量 + 负 bottom 下探），
  更贴近屏幕下沿；`MediaQuery.padding.bottom` 安全区完整保留，不会压到手势条。
- **横屏控制栏收紧**：原来 `buttonScale = isLarge ? 1.3 : 1.0`，手机横屏后宽度
  超过平板阈值被误判成「大屏」，所有间距/字号/按钮放大 30%。现在横屏用
  **0.85**，间距更小、按钮更小；时间字号加 `clamp(10,14)` 保底 10px 不糊。

> 这是 Flutter 共用代码，**Android 与 iOS 同时生效**。

---

## 历史版本改动（v1.1.2）

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

## 七、Android 8 / 9：二级菜单被导航栏遮挡（修复）

**现象**：Android 8 设备上，多个二级菜单的下半部分被系统导航栏盖住，
**被挡住的地方既滑不到也点不到**。

### 根因（两层叠加）

**第一层：主题让导航栏透明，内容实际压在它下面**

`values/styles.xml` 里：

```xml
<item name="android:navigationBarColor">@android:color/transparent</item>
<item name="android:windowDrawsSystemBarBackgrounds">true</item>
```

这是为 Android 10+ 的 `edgeToEdge` 准备的。但 Android 8 只支持 `manual`
模式，而 Flutter 的 `setSystemUIOverlayStyle` 在 Android 8.0 上设置
`navigationBarColor` 有已知缺陷，经常静默失效。于是形成矛盾：

- 系统认为「内容不延伸」→ `MediaQuery.padding.bottom` = 0
- 主题里导航栏仍是 transparent → 内容确实画到了导航栏底下

**第二层：Dart 侧拿不到真实高度**

`showModalBottomSheet` 是浮在最上层、**覆盖整个物理屏幕**的浮层，
它不参与「扣掉导航栏」的布局计算。但代码里判断要留多少空白时用的
`viewPadding.bottom` / `SafeArea`，在低版本的 manual 模式下都返回 **0**。

两者叠加：算出「不需要留白」，浮层却压在导航栏上。

### 修复

**① 主题层**：新增 `values-v26/styles.xml`，在 API 26/27 上让系统画
不透明导航栏（`#F2F2F7`）并关掉 `windowDrawsSystemBarBackgrounds`，
系统会真正把导航栏区域从布局里扣掉。

**② 原生实测高度**：新增 `getNavigationBarHeightDp()` 方法，三级降级：

| 优先级 | 方法 | 适用 |
|---|---|---|
| 1 | `WindowInsets.getInsets(navigationBars)` | API 30+ |
| 2 | `getRealMetrics` 高度差 − 状态栏 | API 17+ |
| 3 | 系统资源 `navigation_bar_height` | 兜底 |

**③ Dart 侧统一入口**：新增 `SystemUiPolicy.bottomSheetInset(mq)`，
优先级为 **原生实测 > viewPadding > padding > 常量兜底（48dp）**。
启动时读一次缓存，`bottomSheetInset` 同步取用。

### 修复覆盖的全部浮层（8 处）

第一版只改了设置页，实际排查后发现全项目有 8 处底部浮层都有这个问题：

| 位置 | 弹窗 |
|---|---|
| `widgets/glass/glass_sheet.dart` | **通用封装**，全项目底部弹窗统一入口 |
| 播放页 | 视频详情面板 |
| 播放页 | 字幕选择面板 |
| 播放页 | 音轨选择面板 |
| 播放页 | 倍速选择面板 |
| 播放页 | 投屏设备面板 |
| 刮削 | 「手动匹配」弹窗 |
| 云盘 | 「选择云盘」弹窗 |
| iPad | 「iPad Pro 已就绪」提示 |

### 已确认无需修改

- `showDialog` / `AlertDialog` 类：居中显示，不贴屏幕底，不受导航栏影响
- `adaptive_scaffold` 的 mini player：用 `viewPadding` 定位是正确的
- `glass_nav_bar`：manual 模式下系统已扣掉导航栏，导航栏自身不需要再补

### 顺带修复

`_pickerSheet` 原来是无滚动的 `Column`，选项多时（如 7 个速度档）
在矮屏上会直接溢出。已套 `SingleChildScrollView`。

---

## 八、NAS / 串流：看不到文件、无法修改删除（修复）

### ① WebDAV 目录被全部跳过（看不到文件的根因）

**现象**：添加 NAS 连接后点进去，连接没报错，但**目录是空的**，看不到任何文件。

**根因**：解析 WebDAV 响应的代码里有这一行：

```dart
if (href.endsWith('/') && !href.contains('?')) continue; // skip dirs
```

WebDAV 规范里**目录的 href 一定以 `/` 结尾**，所以这行把所有目录都丢掉了，只剩文件。如果配置的目录下只有子文件夹（电影放在子文件夹里很常见），列表就完全空白。

同一份真实响应的实测对比：

| 实现 | 结果 |
|---|---|
| 修复前 | 1 项（0 目录 + 1 文件） |
| 修复后 | 3 项（2 目录 + 1 文件） |

**修复**：只跳过「当前请求目录自身」那一条（WebDAV 响应第一条固定是自身），其余全部保留。

### ② FTP 子目录路径丢失

`_parseFtpList` 里 path 写死为 `/$name`，把父目录层级丢了 ——
进入子目录后返回的路径全错，表现为「进得去、退不回、点文件播不了」。
已改为拼上 `basePath`。

### ③ 失败被伪装成「空目录」

`listDirectory` 内部 catch 所有异常返回空数组，上层无法区分「目录真的空」和「路径错/认证失败」。现在会显示具体原因：

| 状态码 | 提示 |
|---|---|
| 401 | 认证失败（用户名或密码错误） |
| 403 | 无访问权限 |
| 404 | 路径不存在（并提示可能需要在「路径」里填 `/dav`） |
| 405 | 该地址不是 WebDAV 端点 |

### ④ 连接无法修改、无法删除

**现象**：添加完 NAS 连接后就锁死了 —— 卡片只有「点一下去连接」，没有编辑、也没有删除入口。密码填错或路径写错只能重装 App。

**修复**：
- 连接卡片右侧加溢出菜单（⋯），含「修改连接」「删除连接」
- 删除前二次确认，明确说明「只移除本机配置，不影响 NAS 上的文件」
- 添加对话框支持编辑模式：标题变「修改 NAS 连接」、字段预填（含密码）、按钮变「保存」

**实现要点**：`updateConnection` 会**先断开旧连接**再替换配置。因为 `_NasConnection` 里缓存着 HttpClient / FTP socket / SMB pool，都拿着旧的主机和凭据 —— 不断开的话，改完密码再连接仍走旧连接，表现为「改了没用」。

### ⑤ 路径填写提示

WebDAV 的「路径」不是可选的，各家不同：

| 服务 | 路径 |
|---|---|
| 群晖 | `/dav` |
| 威联通 | `/dav` |
| Nextcloud | `/remote.php/dav/files/用户名` |
| 通用 | 留空按 `/`（很多服务器在根目录返回 404/405） |

填错会在列表页直接提示「路径不存在」。

---

### ⑥ 播放后返回再点连接无反应（修复）

**现象**：浏览 NAS 文件 → 播放视频 → 返回 NAS 主页 → 再点「我的 NAS」，
**点了完全没反应**，必须杀掉 App 重进才能恢复。

**根因**：连接复用的判断只信任一个历史标志。

```dart
var c = _conns[config.id];
if (c != null && c.connected) return true;   // 无脑信任
```

`connected` 只表示「上次 connect 成功过」，**不代表底层连接还活着**。
播放器（media_kit）用同一台 NAS 的 URL 拉流，可能把 HttpClient 里那条
keep-alive 连接用掉或半关闭。返回主页再点连接时：

- `connected` 仍是 true → 直接 `return true`（以为成功）
- 底层连接已废 → 紧接着的 `PROPFIND` 失败
- UI 上就是「点了没反应」，且没有任何错误提示

**实测复现**（模拟底层连接被破坏）：

| 逻辑 | connect 返回 | 随后 PROPFIND |
|---|---|---|
| 修复前 | `true`（声称成功） | **失败** ← 点了没反应 |
| 修复后 | `true` | 成功，读到 1068 字节 |

**修复**：

1. **复用前必须 ping 验证** —— 新增 `ping()` 发轻量 OPTIONS，
   3 秒硬超时。注意用 `Future.any` 而不是 `connectionTimeout`：
   后者只管「建立连接」，连接已建立但对端不回包时会一直等下去。
   失败即断开旧连接、重建。
2. **connect 时关掉旧 HttpClient** —— 原来每次 new 却从不 close，
   反复往返会累积连接池。顺带把 `idleTimeout` 设为 5 秒。
3. **provider 层兜底重试** —— 若连接成功但首次读目录失败，
   强制断开重建一次再试，保证不杀 App 也能恢复。

---
## 九、诊断日志（新功能）

**为什么加这个**：之前排查问题需要「抓 logcat」，但手机上根本不现实 ——
要连电脑、或用专门工具。只能靠用户描述「点了没反应」，而这类描述往往
丢了最关键的信息（哪个接口、什么状态码、什么异常）。

**位置**：设置 → 关于 →「诊断日志」

面板里可以：

- 滚动查看全文（可选中局部复制）
- **一键复制全部** —— 粘贴到微信/邮件发出来即可
- 清空 —— 复现问题前先清空，能只保留本次操作的日志

报告头部自动带上**版本号、设备品牌、RAM、导航方式**（手势/三键）——
这些是判断问题类型的关键上下文，例如导航栏遮挡就与导航方式直接相关。

**技术实现**：劫持 `debugPrint`（它是可赋值的顶层变量），在 `main()`
最开头安装，因此能捕获全项目 100+ 处日志以及第三方库的输出，**零侵入**——
不需要逐个改调用点。日志存在环形缓冲区里，只保留最近 800 条
（播放时每秒数条，不设上限会吃光内存；排查只需要出问题前后那一段）。

同时接入 `FlutterError.onError` 和 `runZonedGuarded`，未处理异常也会进日志，
堆栈保留前 12 帧。

**日志只存本机，不上传任何服务器。**

---

## 已知限制

- **iOS 画中画**仍未实现（按钮不显示）
- **照片库视频需先导出**：首次扫描大相册会花一些时间（已做索引去重，第二次起几乎瞬时）
- **iOS 应用内更新**：受 iOS 限制无法自安装，只提供「复制下载链接」引导（用 AltStore 等工具装 IPA）
- 网盘相关限制同前版本（115 大文件、夸克限速、百度/阿里 OAuth）

