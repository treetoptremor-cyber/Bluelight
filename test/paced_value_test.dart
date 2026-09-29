import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hue_ble_remote/paced_value.dart';

/// A fake bulb link: each write takes [latency] and is recorded.
class _Link {
  _Link(this.latency);

  final Duration latency;
  final writes = <(int, bool)>[];
  int inFlight = 0;
  int maxInFlight = 0;
  Object? failWith;

  Future<void> send(int value, {required bool confirmed}) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    writes.add((value, confirmed));
    await Future<void>.delayed(latency);
    inFlight--;
    final e = failWith;
    if (e != null) throw e;
  }
}

void main() {
  test('first value goes out at once, later ones coalesce to the newest', () {
    fakeAsync((async) {
      final link = _Link(const Duration(milliseconds: 50));
      final v = PacedValue<int>(send: link.send);
      v.start(1);
      for (var i = 1; i <= 10; i++) {
        v.update(i);
        async.elapse(const Duration(milliseconds: 2));
      }
      async.elapse(const Duration(seconds: 1));
      expect(link.writes.map((w) => w.$1), [1, 10]);
      expect(link.maxInFlight, 1);
    });
  });

  test('never more than one write per interval, even on a fast link', () {
    fakeAsync((async) {
      final link = _Link(const Duration(milliseconds: 5));
      final times = <Duration>[];
      final v = PacedValue<int>(
        send: (value, {required confirmed}) {
          times.add(async.elapsed);
          return link.send(value, confirmed: confirmed);
        },
      );
      v.start(0);
      // A drag event every 8 ms (~120 Hz) for 400 ms.
      for (var i = 0; i < 50; i++) {
        v.update(i);
        async.elapse(const Duration(milliseconds: 8));
      }
      v.end(99);
      async.elapse(const Duration(seconds: 1));
      for (var i = 1; i < times.length; i++) {
        expect(
          times[i] - times[i - 1],
          greaterThanOrEqualTo(const Duration(milliseconds: 40)),
        );
      }
      // ~25 writes per second rather than one per drag event.
      expect(times.length, inInclusiveRange(9, 12));
      expect(link.writes.last, (99, true));
    });
  });

  test('mid-drag values are unconfirmed, the release value is confirmed', () {
    fakeAsync((async) {
      final link = _Link(const Duration(milliseconds: 50));
      final v = PacedValue<int>(send: link.send);
      v.start(1);
      v.update(1);
      async.elapse(const Duration(milliseconds: 100));
      v.update(2);
      async.elapse(const Duration(milliseconds: 100));
      v.end(3);
      async.elapse(const Duration(seconds: 1));
      expect(link.writes, [(1, false), (2, false), (3, true)]);
    });
  });

  test('holds the shown value while dragging and for the settle time', () {
    fakeAsync((async) {
      final link = _Link(const Duration(milliseconds: 50));
      final v = PacedValue<int>(send: link.send);
      var notified = 0;
      v.addListener(() => notified++);

      expect(v.shown, isNull);
      v.start(5);
      v.update(7);
      expect(v.shown, 7);
      expect(v.dragging, isTrue);

      async.elapse(const Duration(seconds: 5));
      expect(v.shown, 7, reason: 'still dragging');

      v.end(8);
      expect(v.dragging, isFalse);
      async.elapse(const Duration(milliseconds: 50)); // write done
      async.elapse(const Duration(milliseconds: 650));
      expect(v.shown, 8, reason: 'inside the settle window');
      final before = notified;
      async.elapse(const Duration(milliseconds: 100));
      expect(v.shown, isNull);
      expect(notified, before + 1);
    });
  });

  test('a new drag during the settle window keeps holding', () {
    fakeAsync((async) {
      final link = _Link(const Duration(milliseconds: 50));
      final v = PacedValue<int>(send: link.send);
      v.set(1);
      async.elapse(const Duration(milliseconds: 400));
      v.start(2);
      async.elapse(const Duration(seconds: 2));
      expect(v.shown, 2);
    });
  });

  test('errors are reported and pacing carries on', () {
    fakeAsync((async) {
      final link = _Link(const Duration(milliseconds: 10))
        ..failWith = StateError('gone');
      final errors = <Object>[];
      final v = PacedValue<int>(send: link.send, onError: errors.add);
      v.set(1);
      async.elapse(const Duration(milliseconds: 100));
      v.set(2);
      async.elapse(const Duration(seconds: 1));
      expect(errors, hasLength(2));
      expect(link.writes.map((w) => w.$1), [1, 2]);
      expect(v.shown, isNull);
    });
  });

  test('reset drops the pending write and the held value', () {
    fakeAsync((async) {
      final link = _Link(const Duration(milliseconds: 50));
      final v = PacedValue<int>(send: link.send);
      v.start(1);
      v.update(1);
      v.update(2); // pending behind the first write
      v.reset();
      async.elapse(const Duration(seconds: 1));
      expect(link.writes.map((w) => w.$1), [1]);
      expect(v.shown, isNull);
      expect(v.dragging, isFalse);
    });
  });
}
