import 'package:shared_preferences/shared_preferences.dart';

/// 输入框草稿的落盘层：每个「主机 + 会话」一段文本。
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

  SharedPreferences? _prefs;

  static String keyFor(String hostId, String sessionId) =>
      '$keyPrefix$hostId.$sessionId';

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

  /// 发出去之后清掉草稿（内容已经变成气泡，留着会让下次输入框凭空多一段）。
  Future<void> clear(String hostId, String sessionId) async {
    try {
      final prefs = await _prefsOrLoad();
      await prefs.remove(keyFor(hostId, sessionId));
    } catch (_) {
      // 同上。
    }
  }
}
