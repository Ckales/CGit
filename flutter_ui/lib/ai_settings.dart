import 'package:shared_preferences/shared_preferences.dart';

/// The default system prompt, verbatim from the Tauri app so both frontends
/// produce the same kind of message from the same diff.
const defaultAiPrompt = '''你是一个 Git 提交说明生成器。根据用户给出的 git diff 生成一条提交说明。
要求：
1. 第一行是不超过 50 个字的概要，使用中文，不要加句号。
2. 如果改动涉及多个方面，空一行后用「- 」列出要点，每行一条。
3. 只描述改动本身，不要解释 diff 语法，不要输出代码块标记。
4. 直接输出提交说明正文，不要任何前缀或额外说明。''';

/// AI settings, all in shared_preferences — the token included, matching the
/// Tauri app's localStorage boundary (AGENTS.md).
///
/// The token used to live in the login Keychain. This app is ad-hoc signed, so
/// every rebuild changes its signature and "始终允许" stops matching: macOS asked
/// for the login password again after each restart.
class AiSettings {
  AiSettings._(this._store);

  static const _keyBaseUrl = 'cgit.ai.baseUrl';
  static const _keyModel = 'cgit.ai.model';
  static const _keyPrompt = 'cgit.ai.prompt';
  static const _keyToken = 'cgit.ai.token';

  static Future<AiSettings> load() async =>
      AiSettings._(await SharedPreferences.getInstance());

  final SharedPreferences _store;

  String get baseUrl => _store.getString(_keyBaseUrl) ?? '';
  Future<void> setBaseUrl(String v) => _store.setString(_keyBaseUrl, v.trim());

  String get model => _store.getString(_keyModel) ?? '';
  Future<void> setModel(String v) => _store.setString(_keyModel, v.trim());

  String get prompt => _store.getString(_keyPrompt) ?? defaultAiPrompt;
  Future<void> setPrompt(String v) => _store.setString(_keyPrompt, v);

  /// Null when nothing is stored.
  Future<String?> readToken() async => _store.getString(_keyToken);

  /// Writing an empty string deletes the key rather than storing "", so
  /// clearing the field really removes the credential.
  Future<void> writeToken(String token) async {
    final value = token.trim();
    if (value.isEmpty) {
      await _store.remove(_keyToken);
      return;
    }
    await _store.setString(_keyToken, value);
  }

  /// Whether generation can even be attempted. Checked before the button is
  /// enabled so an unconfigured endpoint is visible rather than a failed call.
  bool get isConfigured => baseUrl.isNotEmpty && model.isNotEmpty;
}
