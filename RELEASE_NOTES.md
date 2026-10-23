# PerchPlay v1.1.0 更新说明

本次是一个较大的修复版本，重点解决**网盘登录/播放**与**界面遮挡**两类问题。

---

## 一、网盘

### 115 网盘：大文件直链（新增）

之前 115 的直链获取有三个缺陷，导致「直链获取失败」：

- **不检查接口的 `state` 字段**。失败时服务端返回 `{"state":false,"error":"请重新登录","errno":99}`，`data` 是空数组。旧代码只看 `data is Map`，不成立就直接返回 null，把「登录过期」这个真实原因丢掉了。
- **成功时 `data` 是 RSA 加密字符串，不是 Map**。所以即使鉴权完全正常，这条路径也必然失败。
- **响应字段名是 `file_url`，不是 `url`**。即使拿到明文也提取不到。

现在按三条通道依次降级：

| 通道 | 端点 | 是否加密 | 大小限制 |
|---|---|---|---|
| A | `115.com/?ct=download&ac=video`（302 Location） | 否 | ≤200MB |
| B | `webapi.115.com/files/download` | 否 | ≤200MB |
| C | `proapi/app/chrome/downurl` | **是（已实现解密）** | **无限制** |

小文件走 A/B（更快，一次请求即返回），超过 200MB 自动落到 C。

通道 C 的 RSA 解密用**纯 Dart 的 BigInt 实现**，没有引入任何第三方加密库。链路是：模幂还原 → 剥 PKCS#1 填充 → 取前 16 字节派生 XOR 密钥 → XOR → 逆序 → 再 XOR 固定密钥。该实现用 Python 参考实现交叉验证过（含 208 字节需分段的长明文用例）。

同时修复了 `pickcode` 字段兼容（列表里可能是 `pc` 或 `pickcode`），以及直链 `f` 参数要求的附加 Cookie（`f=3` 时不带会 403）。

### 阿里云盘：登录界面（修复）

**根因是打开错了页面。** 原来打开 `https://www.alipan.com/`，那是产品介绍首页（`aliyun-drive-home`），**没有任何登录入口**，在 WebView 里只看到宣传图。

`https://www.alipan.com/sign/in` 才是登录应用（`aliyun-drive-fe/h5-sign`），有手机号登录和扫码。已改。

同时修正了 token 抓取：
- 优先读 `sessionStorage`（h5-sign 就是这么存的，代码是 `sessionStorage.getItem(L) || localStorage.getItem(L)`），原来只读 localStorage
- 兼容 `tokenDetailInfo` 嵌套结构
- 不再把 token 前 20 字符打进日志

**关于 OAuth2.0**：目前阿里云盘开放平台对第三方应用的 OAuth 授权是关闭的。直接请求 `auth.alipan.com/v2/oauth/authorize` 会返回：

```
403 {"code":"Forbidden",
     "message":"...domain not support oauth."}
```

这与 client_id 无关（空 client_id 返回 400，任意 client_id 返回 403）。真正的 OAuth 端点 `open.aliyundrive.com/oauth/authorize` 需要单独申请应用，且 `redirect_uri` 必须与申请时登记的一致。代码里保留了走 OAuth 的骨架，拿到凭证后可直接切换。

### 百度网盘：读取目录失败（修复）

**根因是 Cookie 抓取时的域名覆盖顺序。**

```dart
final hostsToCheck = [host, 'pan.baidu.com', 'baidu.com'];
for (final h in hostsToCheck) {
  for (final c in cookies) map[c.name] = c.value;   // 后写的覆盖前面的
}
```

百度的关键 Cookie 分散在不同域名：`BDUSS` 在 `.baidu.com`，`STOKEN` 只在 `pan.baidu.com`。查询 `https://baidu.com` 时浏览器会返回所有对其生效的 Cookie，其中可能包含另一个（无效的）`STOKEN`，把前面从 `pan.baidu.com` 拿到的正确值覆盖掉 → 接口返回 `errno: -6`（未登录）。

改为：**先查宽泛域名，再查具体域名**，让精确值覆盖宽泛值。

另外三处修复：
- 登录入口从 `/login` 改为 `pan.baidu.com/disk/main`（`STOKEN` 只在访问网盘页面时下发）
- 补齐 `bdstoken`（CSRF token，从 Cookie 里提取）
- 取直链改走 `api/filemetas`（Cookie 认证）。原代码用 `xpan/multimedia` 但 `access_token` 传的是空值，必然失败

### 网盘错误提示（改进）

之前不管什么失败都提示「登录可能已过期」，用户被误导着反复重新登录，而真实原因可能是目录不存在或账号受限。现在按错误码区分：

| 错误码 | 含义 | 提示 |
|---|---|---|
| `-6` | 未登录/过期 | 重新添加并完成登录 |
| `-7` / `-9` | 目录不存在 | 已删除或改名，返回上一级 |
| `31066` | 账号受限 | 需完成实名认证 |
| 其他 | — | 显示错误码与原始信息 |

夸克也补上了同样处理（取直链接口原来完全不检查业务错误码）。

### 播放缓冲优化（夸克/115/百度/阿里全部生效）

三个问题：

1. **HTTP 请求头手工拼接会被逗号截断**。原代码把 headers 拼成 `'Key:value','Key2:value2'` 塞给 mpv 的 `http-header-fields`，而夸克/百度的 Cookie 本身含逗号，会被拆错 → 鉴权残缺 → 服务端限速或反复 403。改为使用 media_kit 的 `Media(httpHeaders:)`，内部用 `MPV_FORMAT_NODE_ARRAY` 逐条下发，不做字符串拼接。

2. **网络流走了磁盘缓存**。`cache-on-disk=yes` 会把网络流先写进手机存储再读出来，多一次闪存写 + 读。改为 `no`，只保留内存缓存。

3. **起播预读 10 秒**。这是 mpv 默认值，意味着先攒够 10 秒数据才开播。网盘首包本来就慢，叠加后表现为「点开要转圈十几秒」。改为 3 秒。

另外对网盘直链关闭了 mpv 的并发 Range 抢带宽行为（多连接会被判定为异常流量，反而更慢），并调整了 `network-timeout`、`demuxer-lavf-buffersize` 等参数。

### 慢源提示（新增）

网盘（尤其夸克非会员）对第三方直链有**服务端限速**，这是客户端绕不过去的。但以前用户只能对着转圈干等，不知道是网络问题、App 问题还是限速。

现在缓冲超过 8 秒会显示提示：

> 网盘服务器限速，可能因非会员／并发过大。
> 可尝试：切换到 4G/Wi-Fi、换清晰度较低的片源，或把文件转存到本地后播放。

---

## 二、NAS / 串流

### 添加连接的按钮被遮挡（修复）

两个独立问题，根因相同：**浮层不占布局空间，而列表留白没把它算进去**。

**① 添加连接弹窗的按钮被导航栏压住**

弹窗贴屏幕底，而外层 `SafeArea` 是 `bottom: false`（tab 页为了内容铺满特意关掉的），所以 `MediaQuery.padding.bottom` 不生效。滚动区底部只给了 24px，正好落进系统导航栏区域——「连接 / 取消」被压住。

**② 列表最后几项被播放小窗压住**

小窗是浮层，位置在导航栏之上（`bottom = 72 + 手势条`），本身高 64px。但列表只按 96px 留白，小窗出现后实际需要 148px，最后几行正好落在小窗背后点不到。

现在统一用 `MiniPlayer.bottomInset()` 计算，连接列表、文件列表、空状态三处都已改。

### 协议与路径（已是现有能力）

NAS 支持四种协议，都可自定义：

| 协议 | 默认端口 | 需要填写 |
|---|---|---|
| WebDAV | 5005 | 路径（如群晖 `/dav`、Nextcloud `/remote.php/dav/files/用户名`） |
| FTP | 21 | 远程起始路径 |
| SMB | 445 | 共享名（必填） |
| NFS | — | 暂不支持（需内核支持，Dart 层无法实现） |

WebDAV 的路径建议不要留空——很多服务在根目录返回 404/405。

---

## 三、播放器

### 播放界面状态栏不隐藏（修复）

`initState` 里只调用了 `_applyPlayerFullscreenUi()`，它只设置 overlay style：

```dart
SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,   // 只是把底色设透明
  ...
));
```

在 `edgeToEdge` 模式下，`statusBarColor: transparent` **只是让状态栏底色变透明，状态栏本身仍然存在**——它依然占据屏幕顶部空间、依然显示时间电量图标。

真正隐藏需要 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`，而这个调用原来只在用户主动点「全屏」时才执行。

现在进入播放页就调用 `applyImmersive()`，并调整顺序为「先设样式 → 再进沉浸」（反过来会让样式覆盖沉浸状态）。退出全屏时也不再恢复状态栏（此时仍在播放页）。

### 进度条拖动发涩（修复）

四个性能问题叠加：

1. **每帧双重重建**。拖动时 `GlassSlider` 内部 `setState` → 触发 `onChanged` → 改外部 `ValueNotifier` → `ValueListenableBuilder` 重建 → 把新 value 推回滑块 → 再次 `setState`。现在拖动期间滑块完全忽略外部 value。

2. **`AnimatedContainer` 拖后腿**。thumb 位置每帧都变，但 200ms 隐式补间让滑块「追不上手指」。拖动时把时长压到 0。

3. **`boxShadow` 每帧重算模糊蒙版**。活跃轨道的发光效果会随宽度变化每帧重新生成蒙版。拖动时去掉发光，松手后恢复。

4. **`SafeBackdropFilter` 多一层合成**。拖动时跳过。

---

## 四、界面

### 设置页「已隐藏的视频」竖排（修复）

`ListTile` 的 `title` 在 `trailing`（「全部恢复」按钮）占宽后被压缩，而 `Text` 默认允许任意换行。中文没有空格，压到「每行一个字」时就变成竖排文字。

已给 `_settingRow` / `_settingSwitch` 的标题加 `maxLines: 1` + `ellipsis`。空间不够时显示「已隐藏的视频（12…」而不是竖排。

---

## 五、其他修复

- **首页进度条不刷新**。首页卡片读的是 `libraryProvider` 缓存里的 `lastPosition`，而播放结束只递增 `playbackVersionProvider`，provider 没监听它，进度条永远停在旧值。现在 `build()` 会监听版本号并从数据库重读（只重读 DB，不重扫文件系统）。

- **缓冲看门狗串片**。上一部视频正在缓冲时切到下一部，旧定时器 8 秒后会在新视频上误弹「限速」提示。已加代次令牌并在换片时清理。

- **网盘错误提示失效**。`_clients` 原本在 `connect()` 成功后才存，失败路径下 `lastErrorHint()` 取不到 client、永远返回空串，导致「按 errno 区分原因」的逻辑在最需要它的场景（登录过期）下不工作。改为先注册再 connect。

- **阿里云 token 失效后仍返回坏 token**。原兜底会让上层拿一个已验证失败的 token 去发请求，真实原因被掩盖成「列目录失败」。改为返回 null。

- **版本号被硬编码覆盖**。`android/local.properties` 里有 `flutter.versionName=1.0.98`，会覆盖 `pubspec.yaml` 的版本号，导致之前打包版本号一直是 1.0.98。已同步为 1.1.0 / versionCode 110。

---

## 已知限制

- **115 网盘 >200MB 的文件**：走 RSA 解密通道，但真实服务端响应结构未经真机验证，如果失败请提供 `[115]` 开头的日志
- **夸克网盘限速**：服务端行为，非会员尤其明显，客户端无法绕过
- **百度开放平台**：OAuth 需要审核，且通过后也只能访问 `/apps/{应用名}/` 这一个目录，无法读取用户网盘其他位置 —— 因此仍使用 Cookie 方案
- **阿里云盘 OAuth**：需自行申请开放平台应用，当前使用 WebView 抓 token
