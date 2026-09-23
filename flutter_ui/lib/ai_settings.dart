import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'git_frb.dart';

/// The default system prompt, verbatim from the Tauri app so both frontends
/// produce the same kind of message from the same diff.
const defaultAiPrompt = '''你是一个 Git 提交说明生成器。根据用户给出的 git diff 生成一条提交说明。
要求：
1. 第一行是不超过 50 个字的概要，使用中文，不要加句号。
2. 如果改动涉及多个方面，空一行后用「- 」列出要点，每行一条。
3. 只描述改动本身，不要解释 diff 语法，不要输出代码块标记。
4. 直接输出提交说明正文，不要任何前缀或额外说明。''';

/// AI settings, with the token held apart from the rest.
///
/// The Tauri app keeps all of these in WebKit localStorage, including the
/// token — a plain-text file inside the app container. Here the endpoint, model
/// and prompt go to shared_preferences (they are configuration) and the token
/// goes to the Keychain (it is a credential). That is a deliberate improvement
/// over the port source, not an accident of the platform: nothing about
/// Flutter forced it, and AGENTS.md's rule is that credentials stay out of
/// preferences.
class AiSettings {
  AiSettings._(this._store, this._secure);

  static const _keyBaseUrl = 'cgit.ai.baseUrl';
  static const _keyModel = 'cgit.ai.model';
  static const _keyPrompt = 'cgit.ai.prompt';

  /// The Keychain item. Not a preference key — it never touches the plist.
  static const _secureToken = 'cgit.ai.token';

  static Future<AiSettings> load() async => AiSettings._(
        await SharedPreferences.getInstance(),
        // The login keychain, not the data-protection one: that one needs a
        // keychain-access-groups entitlement and a Team ID, and this app is
        // ad-hoc signed, so every write there failed with -34018.
        const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        ),
      );

  final SharedPreferences _store;
  final FlutterSecureStorage _secure;

  String get baseUrl => _store.getString(_keyBaseUrl) ?? '';
  Future<void> setBaseUrl(String v) => _store.setString(_keyBaseUrl, v.trim());

  String get model => _store.getString(_keyModel) ?? '';
  Future<void> setModel(String v) => _store.setString(_keyModel, v.trim());

  String get prompt => _store.getString(_keyPrompt) ?? defaultAiPrompt;
  Future<void> setPrompt(String v) => _store.setString(_keyPrompt, v);

  /// Null when nothing is stored. A failed read (a locked keychain, a denied
  /// or cancelled password prompt) is a [GitError], not null: swallowing it
  /// sent an empty Bearer token and surfaced as a misleading HTTP 401.
  Future<String?> readToken() async {
    try {
      return await _secure.read(key: _secureToken);
    } on PlatformException catch (e) {
      throw GitError('读取钥匙串中的令牌失败：${e.message ?? e.code}');
    }
  }

  /// Writing an empty string deletes the item rather than storing "", so
  /// clearing the field really removes the credential.
  Future<void> writeToken(String token) async {
    final value = token.trim();
    if (value.isEmpty) {
      await _secure.delete(key: _secureToken);
      return;
    }
    await _secure.write(key: _secureToken, value: value);
  }

  /// Whether generation can even be attempted. Checked before the button is
  /// enabled so an unconfigured endpoint is visible rather than a failed call.
  bool get isConfigured => baseUrl.isNotEmpty && model.isNotEmpty;
}
