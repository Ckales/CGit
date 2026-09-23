import 'package:shared_preferences/shared_preferences.dart';

/// Window and view settings that survive a restart.
///
/// The Tauri app keeps these in WebKit `localStorage`; there is no such thing
/// here, so they go through shared_preferences, which writes a plist inside the
/// app's own container. Same durability, same scope — and unlike localStorage
/// it survives a change of web view.
///
/// The AI token deliberately does not live here. It is the one setting worth
/// the Keychain rather than a readable plist, and it lands when the AI feature
/// does rather than being stubbed in now.
class Prefs {
  Prefs._(this._store);

  static const _keyTheme = 'cgit.theme';
  static const _keyDiffView = 'cgit.diffView';
  static const _keySidebarWidth = 'cgit.sidebarWidth';
  static const _keyHistoryHeight = 'cgit.historyHeight';
  static const _keyHistoryPageSize = 'cgit.historyPageSize';
  static const _keyPullStrategy = 'cgit.pullStrategy';
  static const _keyRecentRepos = 'cgit.recentRepos';

  /// How many repositories the 打开 menu remembers. Beyond this the list stops
  /// being a shortcut and becomes something to read.
  static const recentMax = 10;

  static Future<Prefs> load() async =>
      Prefs._(await SharedPreferences.getInstance());

  final SharedPreferences _store;

  /* ---------- appearance ---------- */

  bool get isDark => _store.getString(_keyTheme) != 'light';
  Future<void> setDark(bool dark) =>
      _store.setString(_keyTheme, dark ? 'dark' : 'light');

  bool get isSplitDiff => _store.getString(_keyDiffView) != 'unified';
  Future<void> setSplitDiff(bool split) =>
      _store.setString(_keyDiffView, split ? 'split' : 'unified');

  /* ---------- layout ---------- */

  /// Null means "never dragged", which is what lets the default change later
  /// without overriding a size the user chose.
  double? get sidebarWidth => _store.getDouble(_keySidebarWidth);
  Future<void> setSidebarWidth(double v) =>
      _store.setDouble(_keySidebarWidth, v);

  double? get historyHeight => _store.getDouble(_keyHistoryHeight);
  Future<void> setHistoryHeight(double v) =>
      _store.setDouble(_keyHistoryHeight, v);

  /* ---------- behaviour ---------- */

  int get historyPageSize => _store.getInt(_keyHistoryPageSize) ?? 100;
  Future<void> setHistoryPageSize(int v) =>
      _store.setInt(_keyHistoryPageSize, v);

  /// 'ff-only' | 'merge' | 'rebase'. ff-only is the cue to read git's own
  /// pull.rebase, and to ask when git is silent too.
  String get pullStrategy => _store.getString(_keyPullStrategy) ?? 'ff-only';
  Future<void> setPullStrategy(String v) =>
      _store.setString(_keyPullStrategy, v);

  /* ---------- recent repositories ---------- */

  List<String> get recentRepos => _store.getStringList(_keyRecentRepos) ?? [];

  /// Most recent first, no duplicates, capped. Re-opening a repo moves it to
  /// the top rather than adding a second entry.
  Future<void> rememberRepo(String path) {
    final list = [path, ...recentRepos.where((p) => p != path)];
    return _store.setStringList(
      _keyRecentRepos,
      list.take(recentMax).toList(),
    );
  }

  /// Drop a path that no longer resolves — a repo that was moved or deleted is
  /// worse than useless in a shortcut list.
  Future<void> forgetRepo(String path) => _store.setStringList(
        _keyRecentRepos,
        recentRepos.where((p) => p != path).toList(),
      );
}
