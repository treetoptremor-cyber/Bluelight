import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Asks iOS for background time (about 30 s) while [work] runs, e.g. to
/// finish syncing routines to the bulbs after the phone is locked.
abstract final class BackgroundTask {
  static const _channel = MethodChannel('hue_ble_remote/widgets');

  static Future<T> run<T>(Future<T> Function() work) async {
    int? id;
    if (Platform.isIOS) {
      try {
        id = await _channel.invokeMethod<int>('beginBackgroundTask');
      } catch (_) {
        // Not available: run anyway.
      }
    }
    try {
      return await work();
    } finally {
      if (id != null) {
        try {
          await _channel.invokeMethod<void>('endBackgroundTask', id);
        } catch (_) {
          // Nothing to end.
        }
      }
    }
  }
}
