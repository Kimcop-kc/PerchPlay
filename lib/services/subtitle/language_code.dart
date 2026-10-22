/// 语言代码归一化工具。
///
/// 不同字幕服务返回的语言标识格式不一：
/// - OpenSubtitles 用 ISO 639-1（`en`、`zh`）或 639-2/B（`eng`、`chi`）
/// - SubDL 用全名（`English`、`Chinese`）
/// - 部分服务返回 `zh-CN`、`pt-BR` 等带地区后缀
///
/// 统一归一化为 ISO 639-1 小写两字母代码（无法归一时保留原值小写）。
class LanguageCode {
  LanguageCode._();

  /// 三字母 / 全名 → 两字母 ISO 639-1 映射。
  static const Map<String, String> _map = {
    'eng': 'en',
    'english': 'en',
    'chi': 'zh',
    'zho': 'zh',
    'zh-cn': 'zh',
    'zh-hans': 'zh',
    'zh-tw': 'zh',
    'zh-hant': 'zh',
    'chinese': 'zh',
    'chs': 'zh',
    'cht': 'zh',
    'jpn': 'ja',
    'japanese': 'ja',
    'kor': 'ko',
    'korean': 'ko',
    'fre': 'fr',
    'fra': 'fr',
    'french': 'fr',
    'ger': 'de',
    'deu': 'de',
    'german': 'de',
    'spa': 'es',
    'spanish': 'es',
    'rus': 'ru',
    'russian': 'ru',
    'por': 'pt',
    'pt-br': 'pt',
    'portuguese': 'pt',
    'ita': 'it',
    'italian': 'it',
    'ara': 'ar',
    'arabic': 'ar',
    'hin': 'hi',
    'hindi': 'hi',
    'ind': 'id',
    'indonesian': 'id',
    'vie': 'vi',
    'vietnamese': 'vi',
    'tha': 'th',
    'thai': 'th',
    'tur': 'tr',
    'turkish': 'tr',
    'dut': 'nl',
    'nld': 'nl',
    'dutch': 'nl',
    'pol': 'pl',
    'polish': 'pl',
    'swe': 'sv',
    'swedish': 'sv',
    'nor': 'no',
    'norwegian': 'no',
    'dan': 'da',
    'danish': 'da',
    'fin': 'fi',
    'finnish': 'fi',
    'cze': 'cs',
    'ces': 'cs',
    'czech': 'cs',
    'gre': 'el',
    'ell': 'el',
    'greek': 'el',
    'heb': 'he',
    'hebrew': 'he',
    'rum': 'ro',
    'ron': 'ro',
    'romanian': 'ro',
    'hun': 'hu',
    'hungarian': 'hu',
    'ukr': 'uk',
    'ukrainian': 'uk',
    'bul': 'bg',
    'bulgarian': 'bg',
    'cat': 'ca',
    'catalan': 'ca',
  };

  /// 语言显示名映射（ISO 639-1 → 中文名，用于 UI 展示）。
  static const Map<String, String> _displayNames = {
    'zh': '中文',
    'en': '英文',
    'ja': '日文',
    'ko': '韩文',
    'fr': '法文',
    'de': '德文',
    'es': '西班牙文',
    'ru': '俄文',
    'pt': '葡萄牙文',
    'it': '意大利文',
    'ar': '阿拉伯文',
    'hi': '印地文',
    'id': '印尼文',
    'vi': '越南文',
    'th': '泰文',
    'tr': '土耳其文',
    'nl': '荷兰文',
    'pl': '波兰文',
    'sv': '瑞典文',
    'no': '挪威文',
    'da': '丹麦文',
    'fi': '芬兰文',
    'cs': '捷克文',
    'el': '希腊文',
    'he': '希伯来文',
    'ro': '罗马尼亚文',
    'hu': '匈牙利文',
    'uk': '乌克兰文',
    'bg': '保加利亚文',
    'ca': '加泰罗尼亚文',
  };

  /// 归一化语言代码。
  ///
  /// 输入 `English` → `en`，`zh-CN` → `zh`，`chi` → `zh`。
  /// 无法识别时返回原值小写（如 `xx`）。
  static String normalize(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final key = raw.trim().toLowerCase();
    // 先看直接命中两字母
    if (_map.containsKey(key)) return _map[key]!;
    // 去掉地区后缀再试（`zh-cn` → `zh`）
    if (key.contains('-')) {
      final base = key.split('-').first;
      if (_map.containsKey(base)) return _map[base]!;
      if (base.length == 2) return base;
    }
    // 三字母可能是 639-2
    if (_map.containsKey(key)) return _map[key]!;
    // 已经是两字母小写，直接返回
    if (key.length == 2) return key;
    return key;
  }

  /// 语言显示名（中文）。未知代码返回原代码。
  static String displayName(String code) {
    final normalized = normalize(code);
    return _displayNames[normalized] ?? normalized;
  }
}
