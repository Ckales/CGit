import 'dart:async';

/// Collapses a burst of watcher events into one refresh, and decides how deep
/// that refresh has to be.
///
/// The rule worth isolating: `refs` is sticky across the window. git writes
/// several files for one command, so a commit produces both a ref move and
/// working-tree noise. If the last event in the burst decided the depth, an
/// edit arriving after the ref move would downgrade the refresh and leave the
/// branch labels and the graph stale.
class WatchDebounce {
  WatchDebounce({
    required this.onRefresh,
    this.window = const Duration(milliseconds: 250),
  });

  /// Called once per burst with whether a full refresh is needed.
  final void Function(bool full) onRefresh;
  final Duration window;

  Timer? _timer;
  bool _pendingRefs = false;

  void add(String kind) {
    if (kind == 'refs') _pendingRefs = true;
    _timer?.cancel();
    _timer = Timer(window, _fire);
  }

  void _fire() {
    final full = _pendingRefs;
    _pendingRefs = false;
    onRefresh(full);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pendingRefs = false;
  }
}
