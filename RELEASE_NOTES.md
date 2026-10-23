# PerchPlay 更新说明

## 本次更新（v1.0.104）— 阿里云盘登录修复

对照[官方 OAuth2.0 接入流程](https://help.aliyun.com/zh/pds/drive-and-photo-service-dev/user-guide/oauth-2-0-access-process-for-web-server-applications)重写了阿里云盘的认证链路。

### 1. token 请求改为 form 编码（关键）
官方文档要求 `POST /v2/account/token` 使用 `application/x-www-form-urlencoded`。
原代码发的是 JSON，服务端一律返回 400，所以**永远换不到 token**。现已改为 form 编码。

### 2. access_token 不再被误判过期
原 `_isTokenExpired()` 在本地没有过期时间记录时返回 `true`（保守假设已过期），
导致刚抓到的 access_token 被丢弃，转头去走 refresh_token —— 而 refresh_token 常因
client_id 不匹配失败，最终整体登录失败。现已改为**先用真实请求验证** token，
验证失败才去刷新。

### 3. hasCredential 判定修正
原来只检查 `refreshToken` 是否为空。WebView 登录拿到 access_token 但
refresh_token 缺失时，账号被误判为未登录。现在 access_token 或
refresh_token 任一存在即算有效。

### 4. drive_id 补探测
阿里列目录 / 取直链接口**必须**带 drive_id。原来 `_probeDriveId` 在
getDriveInfo 返回 200 但 `default_drive_id` 为空时直接返回空串提前结束，
导致后续所有请求缺 drive_id 而失败 —— 表现正是「登录成功但网盘打不开」。
现在空值时继续降级到 open API / listDrives 探测，并在列目录、取直链前补探测。

### 5. 直链播放补 Authorization 头
部分账号/文件校验 Bearer 头，不带会 403。现已带上 token + Referer + UA。

### 6. token 失效自动重试
列目录 / 取直链失败时强制刷新 token 并重试一次。

### 7. 日志脱敏
不再把 token 前 20 个字符打进日志。

---

## 历史修复（v1.0.100 ~ v1.0.103）

- **全屏状态栏不隐藏**：进入 immersive 后不再调 `setSystemUIOverlayStyle`
  （会覆盖沉浸模式导致状态栏显示为透明浮层）
- **从列表播放闪退**：移除 dispose / lifecycle 中对 provider 的 `invalidate`
  （widget tree 销毁过程中触发异步重建导致崩溃），改用 `playbackVersionProvider`
- **观看历史**：历史页改用 `playHistoryProvider` 实时查 DB；入口加文件存在性检查
