import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/prompt_image.dart';

/// 输入框草稿的落盘层：每个「主机 + 会话」一段文本，加上已经选好、还没发出去的图。
///
/// 为什么要落盘：聊天页是 `Navigator.push` 出来的一层，返回列表就把这一层
/// 连同 `TextEditingController` 一起销毁了。以前打了一半的话随手返回去看一眼
/// 列表，回来就只剩空白输入框——用户的原话是「输入的内容就丢失了」。
///
/// key 形如 `dsh_frp.draft.<hostId>.<sessionId>`。读写失败一律静默降级：
/// 存不下草稿不能把聊天页带崩。
class DraftStore {
  factory DraftStore({SharedPreferences? prefs}) => DraftStore._(prefs);

  DraftStore._(this._prefs);

  /// 存储 key 前缀。
  static const String keyPrefix = 'dsh_frp.draft.';

  /// 待发图片单独一把 key：文本用原来的 key 不变，老草稿照旧读得出来，
  /// 也不用为了「带图」把纯文本草稿改成 JSON（用户真的会打 `{` 开头的内容）。
  static const String imagesKeyPrefix = 'dsh_frp.draft.images.';

  SharedPreferences? _prefs;

  static String keyFor(String hostId, String sessionId) =>
      '$keyPrefix$hostId.$sessionId';

  /// 某个会话待发图片的存储 key。
  static String imagesKeyFor(String hostId, String sessionId) =>
      '$imagesKeyPrefix$hostId.$sessionId';

  Future<SharedPreferences> _prefsOrLoad() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// 读取草稿；没有、读坏了都返回空串。
  Future<String> load(String hostId, String sessionId) async {
    try {
      final prefs = await _prefsOrLoad();
      return prefs.getString(keyFor(hostId, sessionId)) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 写草稿。空串等价于删除，别在磁盘里留一堆空 key。
  Future<void> save(String hostId, String sessionId, String text) async {
    try {
      final prefs = await _prefsOrLoad();
      final key = keyFor(hostId, sessionId);
      if (text.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, text);
      }
    } catch (_) {
      // 见上：存不下就算了，本轮输入框里的内容是对的。
    }
  }

  /// 读取待发图片；没有、读坏了都返回空表。
  Future<List<PromptImage>> loadImages(String hostId, String sessionId) async {
    try {
      final prefs = await _prefsOrLoad();
      final raw = prefs.getString(imagesKeyFor(hostId, sessionId));
      if (raw == null || raw.isEmpty) return <PromptImage>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <PromptImage>[];
      final images = <PromptImage>[];
      for (final item in decoded) {
        final image = PromptImage.fromJson(item);
        if (image != null) images.add(image);
      }
      return images;
    } catch (_) {
      return <PromptImage>[];
    }
  }

  /// 写待发图片。空表等价于删除。
  ///
  /// 图片是 base64 存整串的：和 outbox 一个取舍——一张图几 MB，不至于让
  /// 一次写盘变成卡顿源，但换来的是一张图都不用额外管文件生命周期。
  Future<void> saveImages(
    String hostId,
    String sessionId,
    List<PromptImage> images,
  ) async {
    try {
      final prefs = await _prefsOrLoad();
      final key = imagesKeyFor(hostId, sessionId);
      if (images.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(
          key,
          jsonEncode(<Object?>[for (final image in images) image.toJson()]),
        );
      }
    } catch (_) {
      // 同上：存不下就算了，本轮输入区里的图还在。
    }
  }

  /// 发出去之后清掉草稿（内容已经变成气泡，留着会让下次输入框凭空多一段）。
  Future<void> clear(String hostId, String sessionId) async {
    try {
      final prefs = await _prefsOrLoad();
      await prefs.remove(keyFor(hostId, sessionId));
      await prefs.remove(imagesKeyFor(hostId, sessionId));
    } catch (_) {
      // 同上。
    }
  }
}
