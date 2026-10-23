import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/theme/glass_theme.dart';
import '../../../models/cloud_drive_model.dart';

/// 云盘登录页：内嵌 WebView 让用户完成登录，然后自动抓 Cookie。
///
/// ## 为什么用 WebView 而不是让用户手动粘贴 Cookie
/// 手动粘贴要求用户开浏览器 → 开发者工具 → 复制 Cookie，普通用户根本
/// 做不到；而且 Cookie 很长，容易复制不全。WebView 方式用户只需要
/// 「输入账号密码 → 登录」，剩下的我们自动完成。
///
/// ## 抓取时机
/// 不是「页面一加载完就抓」——那时还没登录，Cookie 里没有会话票。
/// 这里持续监听页面跳转 + 定期轮询 Cookie，一旦出现
/// [CloudDriveTypeX.requiredCookieKeys] 里的关键字段就算成功。
class CloudLoginPage extends StatefulWidget {
  final CloudDriveType type;

  const CloudLoginPage({super.key, required this.type});

  @override
  State<CloudLoginPage> createState() => _CloudLoginPageState();
}

class _CloudLoginPageState extends State<CloudLoginPage> {
  InAppWebViewController? _controller;
  CookieManager? _cookieManager;
  bool _saving = false;
  Timer? _pollTimer;

  // 桌面版 UA：夸克/115 检测到手机 UA 会强制跳转下载页，必须伪装成桌面浏览器
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  @override
  void initState() {
    super.initState();
    _cookieManager = CookieManager.instance();
    // 持续轮询：无论 Token 还是 Cookie 类云盘，都定时检查。
    // 阿里云盘等 SPA 登录后可能 onLoadStop 先到、localStorage 后写入，
    // 所以统一用轮询兜底。
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) {
        final c = _controller;
        if (c != null && mounted && !_saving) _tryGrab(c);
      },
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GlassTheme.bg,
      appBar: AppBar(
        backgroundColor: GlassTheme.bg,
        title: Text('登录 ${widget.type.displayName}'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _manualGrab,
              child: const Text('完成'),
            ),
        ],
      ),
      body: Column(
        children: [
          // 提示条：告诉用户下一步做什么
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: GlassTheme.accentPurple.withValues(alpha: 0.08),
            child: Text(
              widget.type.usesToken
                  ? '登录成功后会自动获取凭证。若一直失败，可点右上角「完成」手动重试。'
                  : '登录成功后会自动保存，无需手动操作。',
              style: const TextStyle(
                  color: GlassTheme.textSecondary, fontSize: 12, height: 1.4),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.type.loginUrl)),
              initialSettings: InAppWebViewSettings(
                userAgent: _ua,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                useShouldOverrideUrlLoading: true,
                // 允许混合内容（部分云盘登录页有 http 资源）
                mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                // 桌面版视口：不缩小页面，避免 115/夸克 切换移动版
                useWideViewPort: true,
                loadWithOverviewMode: false,
                supportZoom: true,
                textZoom: 100,
                // 缓存
                cacheEnabled: true,
                // 允许所有类型的 URL 打开
                allowsInlineMediaPlayback: true,
                // Android 需要明确允许文件访问以兼容某些云盘登录页
                allowFileAccessFromFileURLs: true,
                allowUniversalAccessFromFileURLs: true,
              ),
              onWebViewCreated: (c) => _controller = c,
              onLoadStop: (controller, url) => _tryGrab(controller),
              shouldOverrideUrlLoading: (controller, action) async {
                // 每次跳转后都尝试抓一次（登录成功通常伴随跳转）
                Future.delayed(const Duration(milliseconds: 600), () {
                  if (mounted) _tryGrab(controller);
                });
                return NavigationActionPolicy.ALLOW;
              },
              onUpdateVisitedHistory: (controller, url, isReload) {
                Future.delayed(const Duration(milliseconds: 600), () {
                  if (mounted) _tryGrab(controller);
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 抓 Cookie / token 并判断是否登录成功。
  ///
  /// 登录流程通常会跳转多个子域名（如 115: passport.115.com → 115.com；
  /// 百度: passport.baidu.com → pan.baidu.com），所以不能只查当前页面的 cookie。
  /// 这里先查当前 URL，再查目标主域，合并结果。
  Future<void> _tryGrab(InAppWebViewController controller) async {
    if (_saving || !mounted) return;
    try {
      final url = await controller.getUrl();
      if (url == null) return;
      final host = url.host;

      // 收集所有可能域名的 cookie（当前页 + 主域）
      final map = <String, String>{};
      final hostsToCheck = [host, ..._mainDomains(widget.type)];
      for (final h in hostsToCheck) {
        try {
          final cookies =
              await _cookieManager!.getCookies(url: WebUri('https://$h'));
          for (final c in cookies) {
            if (c.name.isNotEmpty) map[c.name] = c.value;
          }
        } catch (_) {}
      }

      // 阿里云盘：从 localStorage 取 access_token / refresh_token（不依赖 cookie）
      if (widget.type.usesToken) {
        final raw = await _extractAliyunRefreshToken(controller);
        if (raw != null && raw.isNotEmpty) {
          // JS 返回 JSON: {"at":"...","rt":"..."}
          try {
            final j = jsonDecode(raw) as Map<String, dynamic>;
            final at = j['at']?.toString() ?? '';
            final rt = j['rt']?.toString() ?? '';
            if (at.isNotEmpty || rt.isNotEmpty) {
              // access_token 能直接调 API（有效期 2h）；refresh_token 用来续期。
              // 两个都存下来：短期靠 at，长期靠 rt 自动刷新。
              await _save(cookie: '', refreshToken: rt, accessToken: at);
            }
          } catch (e) {
            debugPrint('[CloudLogin] 解析 token 失败: $e');
          }
        }
        return;
      }

      // Cookie 类：必须包含关键字段才算登录成功。
      // 加宽检测：不仅检查当前 host，只要 cookie 里有目标 key 就算。
      final required = widget.type.requiredCookieKeys;
      if (required.isEmpty) return;
      final ok = required.every((k) => (map[k] ?? '').isNotEmpty);
      if (!ok) return;

      final cookieStr =
          map.entries.map((e) => '${e.key}=${e.value}').join('; ');
      await _save(cookie: cookieStr, refreshToken: '');
    } catch (e) {
      debugPrint('[CloudLogin] 抓取失败: $e');
    }
  }

  /// 返回该云盘需要收集 cookie 的主域名（不含子域名）。
  List<String> _mainDomains(CloudDriveType type) {
    switch (type) {
      case CloudDriveType.quark:
        return ['pan.quark.cn'];
      case CloudDriveType.pan115:
        return ['115.com', 'm.115.com', 'webapi.115.com', 'proapi.115.com'];
      case CloudDriveType.baidu:
        return ['pan.baidu.com', 'baidu.com'];
      case CloudDriveType.aliyun:
        return ['alipan.com', 'aliyundrive.com'];
    }
  }

  /// 从网页 localStorage/cookie 里找阿里云盘的 refresh_token / access_token。
  ///
  /// 阿里云盘 SPA 登录后会往 localStorage 写 token，但不同版本位置不同：
  ///  - 新版 alipan.com: localStorage.token = {"access_token":"...","refresh_token":"..."}
  ///  - 旧版 aliyundrive.com: 可能在 cookie 或其他 key 里
  ///
  /// **优先返回 access_token**（可直接用于 API 调用，绕开 client_id 限制）；
  /// 降级返回 refresh_token（需走 OAuth 换 access_token，可能因内置
  /// client_id 失效而失败）。
  ///
  /// 返回值是 JSON：`{"at":"...","rt":"..."}`，Dart 端再拆开。
  Future<String?> _extractAliyunRefreshToken(
      InAppWebViewController controller) async {
    const js = r'''
(function(){
  try {
    // 方案1: 从 localStorage.token 取（新版 alipan.com）
    var v = localStorage.getItem('token');
    if (v) {
      try {
        var o = JSON.parse(v);
        if (o) {
          var at = o.access_token || '';
          var rt = o.refresh_token || '';
          if (at || rt) return JSON.stringify({at: at, rt: rt});
        }
      } catch (e) {}
    }
    
    // 方案2: 从 cookie 取（部分情况下 token 在 cookie 里）
    var cookies = document.cookie.split(';');
    for (var i = 0; i < cookies.length; i++) {
      var c = cookies[i].trim();
      if (c.indexOf('token=') === 0 || c.indexOf('refresh_token=') === 0) {
        var val = decodeURIComponent(c.substring(c.indexOf('=') + 1));
        try {
          var o = JSON.parse(val);
          if (o && (o.access_token || o.refresh_token)) {
            return JSON.stringify({at: o.access_token || '', rt: o.refresh_token || ''});
          }
        } catch (e) {
          // 如果是纯 token 字符串
          if (val.length > 50) {
            return JSON.stringify({at: val, rt: ''});
          }
        }
      }
    }
    
    // 方案3: 全量扫描 localStorage + sessionStorage
    var keys = [];
    for (var i = 0; i < localStorage.length; i++) keys.push(localStorage.key(i));
    for (var i = 0; i < sessionStorage.length; i++) keys.push(sessionStorage.key(i));
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      if (!k) continue;
      var v2 = localStorage.getItem(k) || sessionStorage.getItem(k);
      if (!v2) continue;
      if (v2.indexOf('refresh_token') < 0 && v2.indexOf('access_token') < 0) continue;
      try {
        var o = JSON.parse(v2);
        if (o) {
          var at = o.access_token || (o.token && o.token.access_token) || '';
          var rt = o.refresh_token || (o.token && o.token.refresh_token) || '';
          if (at || rt) return JSON.stringify({at: at, rt: rt});
        }
      } catch (e) {
        var am = v2.match(/"access_token"\s*:\s*"([^"]+)"/);
        var rm = v2.match(/"refresh_token"\s*:\s*"([^"]+)"/);
        var at2 = am ? am[1] : '';
        var rt2 = rm ? rm[1] : '';
        if (at2 || rt2) return JSON.stringify({at: at2, rt: rt2});
      }
    }
    
    // 方案4: 从 window 对象取（某些 SPA 会挂在全局）
    if (window.__TOKEN__) {
      try {
        var o = window.__TOKEN__;
        if (o.access_token || o.refresh_token) {
          return JSON.stringify({at: o.access_token || '', rt: o.refresh_token || ''});
        }
      } catch (e) {}
    }
  } catch (e) {}
  return null;
})();
''';
    try {
      final r = await controller.evaluateJavascript(source: js);
      if (r is String && r.isNotEmpty && r != 'null') return r;
    } catch (e) {
      debugPrint('[CloudLogin] 取 token 失败: $e');
    }
    return null;
  }

  /// 用户点「完成」时手动再抓一次；抓不到就提示。
  Future<void> _manualGrab() async {
    final c = _controller;
    if (c != null) await _tryGrab(c);
    if (!_saving && mounted) {
      // _tryGrab 成功时会 pop，走到这里说明没抓到
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('还没检测到登录状态，请先完成登录再点「完成」'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _save({
    required String cookie,
    required String refreshToken,
    String accessToken = '',
  }) async {
    if (_saving || !mounted) return;
    setState(() => _saving = true);

    final type = widget.type;
    final acc = CloudDriveAccount(
      id: '${type.name}_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      name: type.displayName,
      cookie: cookie,
      refreshToken: refreshToken,
      accessToken: accessToken,
      lastConnected: DateTime.now(),
    );

    if (mounted) {
      Navigator.of(context).pop(acc);
    }
  }
}
