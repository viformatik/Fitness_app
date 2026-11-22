// Synthetic, controlled Hive lifecycle tests. No user database or cloud.
// These tests define the candidate contract for overlapping operations; they
// do not establish cross-tab safety or real crash/quota durability.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive/src/binary/frame.dart';
import 'package:hive/src/box/box_impl.dart';
import 'package:hive/src/hive_impl.dart';

import 'hive_clear_interlock_test.dart' as fixture;

class CompactingFixtureBackend extends fixture.FixtureBackend {
  Completer<void>? nextCompactGate;
  int compactions = 0;

  @override
  bool get supportsCompaction => true;

  @override
  Future<void> compact(Iterable<Frame> frames) async {
    compactions++;
    events.add('compact-start');
    final gate = nextCompactGate;
    nextCompactGate = null;
    if (gate != null) await gate.future;
    // Deliberately consume the lazy iterable only after the awaited I/O, as
    // the VM backend can do when earlier backend operations are still pending.
    frames.toList();
    events.add('compact-end');
  }
}

Future<Object?> capture(Future<dynamic> work) async {
  try {
    await work;
    return null;
  } catch (error) {
    return error;
  }
}

Future<BoxImpl<dynamic>> compactingBox(
  CompactingFixtureBackend backend, {
  bool autoCompact = false,
}) async {
  final box = BoxImpl<dynamic>(
    HiveImpl(),
    'synthetic_compacting_box',
    null,
    (_, deleted) => autoCompact && deleted > 0,
    backend,
  );
  await box.initialize();
  return box;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final kind in ['eager', 'lazy']) {
    Future<BoxBase<dynamic>> open(fixture.FixtureBackend backend) =>
        kind == 'eager' ? fixture.eager(backend) : fixture.lazy(backend);

    test('$kind: close is rejected during clear and can be retried', () async {
      final backend = fixture.FixtureBackend();
      final box = await open(backend);
      await box.put('old', 1);
      final events = <BoxEvent>[];
      final subscription = box.watch().listen(events.add);
      final gate = Completer<void>();
      backend.nextClearGate = gate;
      final clearing = capture(box.clear());
      final closeError = await capture(
        box.close(),
      ).timeout(const Duration(seconds: 3));
      final openDuringClear = box.isOpen;
      final beforeCommit = Map<dynamic, dynamic>.of(backend.data);
      gate.complete();
      final clearError = await clearing.timeout(const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
      final sawDeletion = events.any(
        (event) => event.key == 'old' && event.deleted,
      );
      await subscription.cancel();
      if (box.isOpen) await box.close();
      expect(closeError, isA<HiveError>());
      expect(openDuringClear, isTrue);
      expect(beforeCommit, {'old': 1});
      expect(clearError, isNull);
      expect(backend.data, isEmpty);
      expect(sawDeletion, isTrue);
    });

    test(
      '$kind: deleteFromDisk is rejected during clear and can be retried',
      () async {
        final backend = fixture.FixtureBackend();
        final box = await open(backend);
        await box.put('old', 1);
        final gate = Completer<void>();
        backend.nextClearGate = gate;
        final clearing = capture(box.clear());
        final deleteError = await capture(
          box.deleteFromDisk(),
        ).timeout(const Duration(seconds: 3));
        final openDuringClear = box.isOpen;
        final beforeCommit = Map<dynamic, dynamic>.of(backend.data);
        gate.complete();
        final clearError = await clearing.timeout(const Duration(seconds: 3));
        if (box.isOpen) await box.deleteFromDisk();
        expect(deleteError, isA<HiveError>());
        expect(openDuringClear, isTrue);
        expect(beforeCommit, {'old': 1});
        expect(clearError, isNull);
        expect(backend.data, isEmpty);
      },
    );

    test(
      '$kind: watchers get no false delete on clear failure or rejected write',
      () async {
        final backend = fixture.FixtureBackend();
        final box = await open(backend);
        await box.put('old', 1);
        final events = <BoxEvent>[];
        final subscription = box.watch().listen(events.add);
        final gate = Completer<void>();
        backend.nextClearGate = gate;
        backend.failClear = true;
        final clearing = capture(box.clear());
        final writeError = await capture(box.put('blocked', 2));
        gate.complete();
        final clearError = await clearing.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(Duration.zero);
        final eventsBeforeRetry = events.length;
        await box.clear();
        await box.put('after', 3);
        await Future<void>.delayed(Duration.zero);
        await subscription.cancel();
        await box.close();
        expect(writeError, isA<HiveError>());
        expect(clearError, isA<StateError>());
        expect(eventsBeforeRetry, 0);
        expect(events.length, 2);
        expect(events[0].key, 'old');
        expect(events[0].deleted, isTrue);
        expect(events[1].key, 'after');
        expect(events[1].deleted, isFalse);
        expect(events[1].value, 3);
      },
    );
  }

  test('clear waits for an already admitted explicit compact', () async {
    final backend = CompactingFixtureBackend();
    final box = await compactingBox(backend);
    await box.put('old', 1);
    await box.put('old', 2);
    final gate = Completer<void>();
    backend.nextCompactGate = gate;
    final compacting = capture(box.compact());
    final clearing = capture(box.clear());
    await Future<void>.delayed(Duration.zero);
    final clearsBeforeCompactFinishes = backend.clears;
    gate.complete();
    final compactError = await compacting.timeout(const Duration(seconds: 3));
    final clearError = await clearing.timeout(const Duration(seconds: 3));
    final order = List<String>.of(backend.events);
    await box.close();
    expect(clearsBeforeCompactFinishes, 0);
    expect(compactError, isNull);
    expect(clearError, isNull);
    expect(
      order.indexOf('compact-end'),
      lessThan(order.indexOf('clear-start')),
    );
    expect(backend.data, isEmpty);
  });

  test('explicit compact is rejected while clear is in progress', () async {
    final backend = CompactingFixtureBackend();
    final box = await compactingBox(backend);
    await box.put('old', 1);
    await box.put('old', 2);
    final gate = Completer<void>();
    backend.nextClearGate = gate;
    final clearing = capture(box.clear());
    final compactError = await capture(
      box.compact(),
    ).timeout(const Duration(seconds: 3));
    final attempts = backend.compactions;
    gate.complete();
    final clearError = await clearing.timeout(const Duration(seconds: 3));
    await box.close();
    expect(compactError, isA<HiveError>());
    expect(attempts, 0);
    expect(clearError, isNull);
    expect(backend.data, isEmpty);
  });

  test(
    'automatic compaction of an earlier write can finish before clear',
    () async {
      final backend = CompactingFixtureBackend();
      final box = await compactingBox(backend, autoCompact: true);
      await box.put('old', 1);
      final writeGate = Completer<void>();
      final compactGate = Completer<void>();
      backend.nextWriteGate = writeGate;
      backend.nextCompactGate = compactGate;
      final writing = capture(box.put('old', 2));
      final clearing = capture(box.clear());
      writeGate.complete();
      await Future<void>.delayed(Duration.zero);
      final compactStarted = backend.compactions == 1;
      final clearsBeforeCompactFinishes = backend.clears;
      compactGate.complete();
      final writeError = await writing.timeout(const Duration(seconds: 3));
      final clearError = await clearing.timeout(const Duration(seconds: 3));
      final order = List<String>.of(backend.events);
      await box.close();
      expect(compactStarted, isTrue);
      expect(clearsBeforeCompactFinishes, 0);
      expect(writeError, isNull);
      expect(clearError, isNull);
      expect(
        order.indexOf('compact-end'),
        lessThan(order.indexOf('clear-start')),
      );
      expect(backend.data, isEmpty);
    },
  );

  test(
    'temporary VM box reopens after compact, clear and close retry',
    () async {
      final dir = await Directory.systemTemp.createTemp('fitness_lifecycle_');
      final hive = HiveImpl()..init(dir.path);
      Box<dynamic>? box;
      try {
        box = await hive.openBox<dynamic>(
          'synthetic_lifecycle',
          compactionStrategy: (_, _) => false,
        );
        await box.put('old', 1);
        await box.put('old', 2);
        final compacting = box.compact();
        final clearing = box.clear();
        final closeError = await capture(box.close());
        expect(closeError, isA<HiveError>());
        await compacting;
        await clearing;
        await box.put('after', 42);
        await box.flush();
        await box.close();
        box = await hive.openBox<dynamic>('synthetic_lifecycle');
        expect(box.toMap(), {'after': 42});
      } finally {
        if (box != null && box.isOpen) await box.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
