import 'package:cgit_flutter/prefs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferences decide what the window looks like on the next launch, so the
/// cases that matter are the empty store (a fresh install must not look broken)
/// and the recent-repo list, which is the one piece with real bookkeeping.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('defaults on a fresh install', () {
    test('dark theme and split diff', () async {
      final prefs = await Prefs.load();
      expect(prefs.isDark, isTrue);
      expect(prefs.isSplitDiff, isTrue);
      expect(prefs.historyPageSize, 100);
      expect(prefs.pullStrategy, 'ff-only');
    });

    test('layout sizes are null, not zero', () async {
      final prefs = await Prefs.load();
      // Null means "never dragged": the widget picks the default, which can
      // change later without overriding a size the user chose on purpose.
      expect(prefs.sidebarWidth, isNull);
      expect(prefs.historyHeight, isNull);
    });

    test('no recent repositories', () async {
      expect((await Prefs.load()).recentRepos, isEmpty);
    });
  });

  group('round-tripping', () {
    test('appearance survives a reload', () async {
      final first = await Prefs.load();
      await first.setDark(false);
      await first.setSplitDiff(false);

      final second = await Prefs.load();
      expect(second.isDark, isFalse);
      expect(second.isSplitDiff, isFalse);
    });

    test('layout sizes survive a reload', () async {
      final first = await Prefs.load();
      await first.setSidebarWidth(320.5);
      await first.setHistoryHeight(410);

      final second = await Prefs.load();
      expect(second.sidebarWidth, 320.5);
      expect(second.historyHeight, 410);
    });
  });

  group('recent repositories', () {
    test('most recent comes first', () async {
      final prefs = await Prefs.load();
      await prefs.rememberRepo('/a');
      await prefs.rememberRepo('/b');

      expect(prefs.recentRepos, ['/b', '/a']);
    });

    test('re-opening moves a repo up instead of duplicating it', () async {
      final prefs = await Prefs.load();
      await prefs.rememberRepo('/a');
      await prefs.rememberRepo('/b');
      await prefs.rememberRepo('/a');

      expect(prefs.recentRepos, ['/a', '/b']);
    });

    test('the list is capped', () async {
      final prefs = await Prefs.load();
      for (var i = 0; i < Prefs.recentMax + 5; i++) {
        await prefs.rememberRepo('/repo$i');
      }

      expect(prefs.recentRepos.length, Prefs.recentMax);
      // The oldest fall off the end, not the newest.
      expect(prefs.recentRepos.first, '/repo${Prefs.recentMax + 4}');
      expect(prefs.recentRepos, isNot(contains('/repo0')));
    });

    test('a repo that no longer exists can be forgotten', () async {
      final prefs = await Prefs.load();
      await prefs.rememberRepo('/gone');
      await prefs.rememberRepo('/kept');
      await prefs.forgetRepo('/gone');

      expect(prefs.recentRepos, ['/kept']);
    });
  });
}
