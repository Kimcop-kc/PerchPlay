## PerchPlay v1.0.89 — 平板布局优化

### 平板（≥900dp）布局统一

- **设置/播放列表/历史**：内容限宽 720px 居中，自适应水平 padding，不再铺满整个平板宽度
- **串流/投屏**：平板侧栏改用紧凑小标题（18-20px），不再把 36px 大标题硬塞进 300px 侧栏
- **底栏导航**：内容限宽 560px 居中，5 个 tab 不再在宽屏上分散太开
- **NAS/网盘切换按钮**：统一放最右侧（平板侧栏 trailing + 手机标题栏 trailing）

### 验证结果

| 项目 | 结果 |
|------|------|
| `flutter analyze` | 0 errors / 0 warnings |
| `flutter test` | 262 passed |
| `flutter build apk --release` | ✅ 33.9 MB |

### 安装

- 架构：arm64-v8a
- 最低系统：Android 7.0 (API 24)
- 签名：debug key
