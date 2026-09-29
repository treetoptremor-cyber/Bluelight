import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A small on-device log of Bluetooth events and errors, kept in memory and
/// in `Documents/diagnostics.log` so problems seen on the phone can be read
/// later (in the app, or pulled off the device with
/// `xcrun devicectl device copy from --domain-type appDataContainer`).
class Diagnostics extends ChangeNotifier {
  Diagnostics._();

  static final instance = Diagnostics._();

  static const _maxLines = 400;
  static const _fileName = 'diagnostics.log';

  final _lines = <String>[];
  File? _file;
  Future<void> _writes = Future.value();

  List<String> get lines => List.unmodifiable(_lines);

  /// Loads the previous session's lines. Safe to skip (e.g. in tests).
  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/$_fileName');
      if (await _file!.exists()) {
        final old = await _file!.readAsLines();
        _lines.insertAll(0, old.skip(old.length - _maxLines ~/ 2));
      }
      log('app', 'started');
    } catch (_) {
      _file = null;
    }
  }

  /// Records one line: `time [tag] message`.
  void log(String tag, String message) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final t =
        '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final line = '$t [$tag] $message';
    _lines.add(line);
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
    }
    debugPrint(line);
    notifyListeners();
    _persist();
  }

  void _persist() {
    final file = _file;
    if (file == null) return;
    final snapshot = _lines.join('\n');
    // Serialise writes; the whole (small) buffer is rewritten each time.
    _writes = _writes
        .then((_) => file.writeAsString('$snapshot\n', flush: true))
        .catchError((Object _) => file);
  }

  void clear() {
    _lines.clear();
    notifyListeners();
    _persist();
  }
}

/// Shorthand for [Diagnostics.instance.log].
void diag(String tag, String message) => Diagnostics.instance.log(tag, message);
