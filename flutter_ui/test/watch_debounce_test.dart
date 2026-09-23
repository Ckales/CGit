import 'package:cgit_flutter/watch_debounce.dart';
import 'package:flutter_test/flutter_test.dart';

/// The stickiness of `refs` is the whole point of this class. One git command
/// writes several files, so a commit made in a terminal arrives as a ref move
/// plus working-tree noise. If the depth were decided by the last event in the
/// burst, the branch labels and the commit graph would silently stay stale.
void main() {
  const window = Duration(milliseconds: 20);
  final settle = window * 3;

  test('one event triggers one refresh', () async {
    final calls = <bool>[];
    WatchDebounce(onRefresh: calls.add, window: window).add('worktree');

    await Future<void>.delayed(settle);
    expect(calls, [false]);
  });

  test('a burst collapses into a single refresh', () async {
    final calls = <bool>[];
    final d = WatchDebounce(onRefresh: calls.add, window: window);
    for (var i = 0; i < 5; i++) {
      d.add('worktree');
    }

    await Future<void>.delayed(settle);
    expect(calls, [false], reason: 'five events, one refresh');
  });

  test('a ref move anywhere in the burst forces the full refresh', () async {
    final calls = <bool>[];
    final d = WatchDebounce(onRefresh: calls.add, window: window);

    // The ref move arrives first and edits follow — the ordering that a naive
    // "use the last event" implementation gets wrong.
    d.add('refs');
    d.add('worktree');
    d.add('worktree');

    await Future<void>.delayed(settle);
    expect(calls, [true]);
  });

  test('a ref move arriving last also forces it', () async {
    final calls = <bool>[];
    final d = WatchDebounce(onRefresh: calls.add, window: window);
    d.add('worktree');
    d.add('refs');

    await Future<void>.delayed(settle);
    expect(calls, [true]);
  });

  test('stickiness does not leak into the next burst', () async {
    final calls = <bool>[];
    final d = WatchDebounce(onRefresh: calls.add, window: window);

    d.add('refs');
    await Future<void>.delayed(settle);
    d.add('worktree');
    await Future<void>.delayed(settle);

    // A checkout followed later by an unrelated edit must not keep paying for
    // the full refresh forever.
    expect(calls, [true, false]);
  });

  test('cancelling drops a pending refresh and the sticky flag', () async {
    final calls = <bool>[];
    final d = WatchDebounce(onRefresh: calls.add, window: window);

    d.add('refs');
    d.cancel();
    await Future<void>.delayed(settle);
    expect(calls, isEmpty, reason: 'closing a repo must not refresh it');

    // And the next burst starts clean rather than inheriting the cancelled ref.
    d.add('worktree');
    await Future<void>.delayed(settle);
    expect(calls, [false]);
  });
}
