import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Window and view settings that survive a restart.
///
/// They go through shared_preferences, which writes a plist inside the app's
/// own container.
///
/// AI settings (token included) live in [AiSettings], same store.
class Prefs {
  Prefs._(this._store);

  static const _keyTheme = 'cgit.theme';
  static const _keyDiffView = 'cgit.diffView';
  static const _keySidebarWidth = 'cgit.sidebarWidth';
  static const _keyHistoryHeight = 'cgit.historyHeight';
  static const _keyHistoryPageSize = 'cgit.historyPageSize';
  static const _keyPullStrategy = 'cgit.pullStrategy';
  static const _keyFontSize = 'cgit.fontSize';
  static const _keyEditor = 'cgit.editor';
  static const _keyEditors = 'cgit.editors';
  static const _keyProjectEditors = 'cgit.projectEditors';
  static const _keyRecentRepos = 'cgit.recentRepos';
  static const _keyOpLog = 'cgit.opLog';
  static const _keyFlatChanges = 'cgit.flatChanges';

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

  /// The commit sheet's change list: flat paths instead of a folder tree.
  bool get isFlatChanges => _store.getBool(_keyFlatChanges) ?? false;
  Future<void> setFlatChanges(bool flat) =>
      _store.setBool(_keyFlatChanges, flat);

  bool get isSplitDiff => _store.getString(_keyDiffView) != 'unified';
  Future<void> setSplitDiff(bool split) =>
      _store.setString(_keyDiffView, split ? 'split' : 'unified');

  /// The base size everything else is scaled against. Applied once as a text
  /// scale rather than threaded into every style.
  static const fontSizes = [12, 13, 15];
  static const baseFontSize = 13;

  int get fontSize => _store.getInt(_keyFontSize) ?? baseFontSize;
  Future<void> setFontSize(int v) => _store.setInt(_keyFontSize, v);

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

  /// 操作日志开关，默认关。
  bool get opLog => _store.getBool(_keyOpLog) ?? false;
  Future<void> setOpLog(bool v) => _store.setBool(_keyOpLog, v);

  /* ---------- editors ---------- */

  /// The app name used for 编辑文件 and for projects with no choice of their
  /// own. Empty means the system default handler.
  String get editor => _store.getString(_keyEditor) ?? '';
  Future<void> setEditor(String v) => _store.setString(_keyEditor, v);

  /// The editors ticked in settings. Only these appear in the 打开项目 menu —
  /// the scan finds every editor on the machine, which is not the same as the
  /// ones this person uses.
  List<String> get editors => _store.getStringList(_keyEditors) ?? const [];
  Future<void> setEditors(List<String> v) =>
      _store.setStringList(_keyEditors, v);

  /// Per-project editor overrides, keyed by repository path.
  Map<String, String> get projectEditors {
    final raw = _store.getString(_keyProjectEditors);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {for (final e in decoded.entries) e.key: e.value as String};
    } on FormatException {
      // A corrupt entry is dropped rather than repaired: the fallback is the
      // default editor, which is what an absent entry means anyway.
      return const {};
    }
  }

  Future<void> setProjectEditors(Map<String, String> v) =>
      _store.setString(_keyProjectEditors, jsonEncode(v));

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
