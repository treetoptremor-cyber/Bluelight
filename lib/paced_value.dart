import 'dart:async';

import 'package:flutter/foundation.dart';

/// Links a slider (or any control) to a value on the bulb.
///
/// Writes go out as fast as the Bluetooth link allows: never two at once,
/// at most one per [interval], and only the newest value is kept while a
/// write is in flight, so a fast drag never builds a queue. Values sent
/// mid-drag are marked unconfirmed (they may use write-without-response);
/// the value on release is always sent confirmed.
///
/// [shown] is the local value while the user is dragging and for [settle]
/// after the last write finishes. The bulb keeps reporting intermediate
/// values for a while after a change, and this hold stops those late reports
/// from pulling the thumb back. Afterwards [shown] goes back to null and the
/// UI shows the bulb's own value again.
class PacedValue<T extends Object> extends ChangeNotifier {
  PacedValue({
    required this.send,
    this.onError,
    this.interval = const Duration(milliseconds: 40),
    this.settle = const Duration(milliseconds: 700),
  });

  /// Writes [value] to the bulb. [confirmed] is false for mid-drag values.
  final Future<void> Function(T value, {required bool confirmed}) send;
  final void Function(Object error)? onError;
  final Duration interval;
  final Duration settle;

  T? _shown;
  T? _pending;
  bool _pendingConfirmed = false;
  bool _busy = false;
  bool _dragging = false;
  bool _disposed = false;
  Timer? _settleTimer;

  /// The value to display instead of the bulb's, or null to show the bulb's.
  T? get shown => _shown;

  /// Whether the user is currently dragging.
  bool get dragging => _dragging;

  /// Drag started: hold the display, don't write yet.
  void start(T value) {
    _dragging = true;
    _show(value);
  }

  /// Drag moved: display and send (unconfirmed).
  void update(T value) {
    _show(value);
    _queue(value, confirmed: false);
  }

  /// Drag released: display and send confirmed.
  void end(T value) {
    _dragging = false;
    _show(value);
    _queue(value, confirmed: true);
  }

  /// A one-off change such as a tap on a preset.
  void set(T value) => end(value);

  /// Drops any pending write and the held value (e.g. after a disconnect).
  void reset() {
    _pending = null;
    _dragging = false;
    _settleTimer?.cancel();
    if (_shown != null) {
      _shown = null;
      notifyListeners();
    }
  }

  void _show(T value) {
    _settleTimer?.cancel();
    _shown = value;
    notifyListeners();
  }

  void _queue(T value, {required bool confirmed}) {
    _pending = value;
    _pendingConfirmed = confirmed;
    if (!_busy) _pump();
  }

  Future<void> _pump() async {
    _busy = true;
    while (_pending != null && !_disposed) {
      final value = _pending!;
      final confirmed = _pendingConfirmed;
      _pending = null;
      // Started before the write so the interval runs alongside it.
      final gap = Future<void>.delayed(interval);
      try {
        await send(value, confirmed: confirmed);
      } catch (e) {
        if (!_disposed) onError?.call(e);
      }
      // Stay busy for the rest of the interval even if nothing is queued
      // yet, so a value arriving a moment later still waits its turn.
      await gap;
    }
    _busy = false;
    if (!_disposed && !_dragging) {
      _settleTimer = Timer(settle, _release);
    }
  }

  void _release() {
    if (_disposed || _dragging || _busy || _shown == null) return;
    _shown = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    _settleTimer?.cancel();
    super.dispose();
  }
}
