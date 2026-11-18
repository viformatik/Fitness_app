// Synthetic Hive Box tests with a controllable in-memory backend. No diary,
// device database, network or cloud is opened. The web integration is separate.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive/src/backend/storage_backend.dart';
import 'package:hive/src/binary/frame.dart';
import 'package:hive/src/box/box_impl.dart';
import 'package:hive/src/box/keystore.dart';
import 'package:hive/src/box/lazy_box_impl.dart';
import 'package:hive/src/hive_impl.dart';

class FixtureBackend extends StorageBackend {
  final data = <dynamic, dynamic>{};
  final events = <String>[];
  Completer<void>? nextWriteGate, nextClearGate;
  bool failWrite = false, failClear = false;
  int writes = 0, clears = 0;

  @override
  String? get path => null;
  @override
  bool get supportsCompaction => false;

  @override
  Future<void> initialize(
    TypeRegistry registry,
    Keystore keystore,
    bool lazy,
  ) async {
    for (final entry in data.entries) {
      keystore.insert(Frame(entry.key, entry.value), notify: false, lazy: lazy);
    }
  }

  @override
  Future<dynamic> readValue(Frame frame) async => data[frame.key];

  @override
  Future<void> writeFrames(List<Frame> frames) async {
    writes++;
    events.add('write-start');
    final gate = nextWriteGate;
    nextWriteGate = null;
    final failure = failWrite;
    failWrite = false;
    if (gate != null) await gate.future;
    if (failure) {
      events.add('write-fail');
      throw StateError('synthetic write failure');
    }
    for (final frame in frames) {
      if (frame.deleted) {
        data.remove(frame.key);
      } else {
        data[frame.key] = frame.value;
      }
    }
    events.add('write-end');
  }

  @override
  Future<void> clear() async {
    clears++;
    events.add('clear-start');
    final gate = nextClearGate;
    nextClearGate = null;
    final failure = failClear;
    failClear = false;
    if (gate != null) await gate.future;
    if (failure) {
      events.add('clear-fail');
      throw StateError('synthetic clear failure');
    }
    data.clear();
    events.add('clear-end');
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> compact(Iterable<Frame> frames) async {}
  @override
  Future<void> deleteFromDisk() async => data.clear();
  @override
  Future<void> flush() async {}
}

Future<BoxImpl<dynamic>> eager(FixtureBackend backend) async {
  final box = BoxImpl<dynamic>(
    HiveImpl(),
    'fixture',
    null,
    (_, _) => false,
    backend,
  );
  await box.initialize();
  return box;
}

Future<LazyBoxImpl<dynamic>> lazy(FixtureBackend backend) async {
  final box = LazyBoxImpl<dynamic>(
    HiveImpl(),
    'fixture_lazy',
    null,
    (_, _) => false,
    backend,
  );
  await box.initialize();
  return box;
}

Future<bool> rejectedByBarrier(Future<dynamic> future) async {
  try {
    await future;
    return false;
  } on HiveError {
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'writes and a second clear are rejected until active clear finishes',
    () async {
      final backend = FixtureBackend();
      final box = await eager(backend);
      await box.put('old', 1);
      final gate = Completer<void>();
      backend.nextClearGate = gate;
      final clearing = box.clear();
      try {
        expect(await rejectedByBarrier(box.put('after', 2)), isTrue);
        expect(await rejectedByBarrier(box.delete('old')), isTrue);
        expect(await rejectedByBarrier(box.putAll({'more': 3})), isTrue);
        expect(await rejectedByBarrier(box.deleteAll(['old'])), isTrue);
        expect(await rejectedByBarrier(box.clear()), isTrue);
        expect(box.get('old'), 1);
        expect(box.get('after'), isNull);
        expect(backend.data, {'old': 1});
      } finally {
        if (!gate.isCompleted) gate.complete();
        await clearing;
      }
      expect(box.isEmpty, isTrue);
      await box.put('after', 2);
      expect(box.get('after'), 2);
      expect(backend.data, {'after': 2});
      await box.close();
    },
  );

  test('clear waits for an earlier write and blocks later writes', () async {
    final backend = FixtureBackend();
    final box = await eager(backend);
    final gate = Completer<void>();
    backend.nextWriteGate = gate;
    final first = box.put('first', 1);
    final clearing = box.clear();
    try {
      await Future<void>.delayed(Duration.zero);
      expect(backend.clears, 0);
      expect(await rejectedByBarrier(box.put('late', 2)), isTrue);
      expect(box.get('first'), 1); // Hive's existing optimistic put behavior.
    } finally {
      if (!gate.isCompleted) gate.complete();
      await first;
      await clearing;
    }
    expect(
      backend.events.indexOf('write-end'),
      lessThan(backend.events.indexOf('clear-start')),
    );
    expect(box.isEmpty, isTrue);
    expect(backend.data, isEmpty);
    await box.close();
  });

  test('failed clear keeps original state and permits a later retry', () async {
    final backend = FixtureBackend();
    final box = await eager(backend);
    await box.put('old', 1);
    final gate = Completer<void>();
    backend.nextClearGate = gate;
    backend.failClear = true;
    final clearing = box.clear();
    final clearOutcome = expectLater(clearing, throwsStateError);
    try {
      expect(await rejectedByBarrier(box.put('late', 2)), isTrue);
      expect(box.get('old'), 1);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await clearOutcome;
    }
    expect(box.get('old'), 1);
    expect(box.get('late'), isNull);
    expect(backend.data, {'old': 1});
    await box.put('later', 3);
    expect(backend.data, {'old': 1, 'later': 3});
    expect(await box.clear(), 2);
    expect(backend.data, isEmpty);
    await box.close();
  });

  test(
    'failed previous write finishes before clear and is not hidden',
    () async {
      final backend = FixtureBackend();
      final box = await eager(backend);
      await box.put('old', 1);
      final gate = Completer<void>();
      backend.nextWriteGate = gate;
      backend.failWrite = true;
      final writing = box.put('old', 2);
      final writeOutcome = expectLater(writing, throwsStateError);
      final clearing = box.clear();
      try {
        await Future<void>.delayed(Duration.zero);
        expect(backend.clears, 0);
        expect(await rejectedByBarrier(box.put('late', 3)), isTrue);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await writeOutcome;
        await clearing;
      }
      expect(
        backend.events.indexOf('write-fail'),
        lessThan(backend.events.indexOf('clear-start')),
      );
      expect(box.isEmpty, isTrue);
      expect(backend.data, isEmpty);
      await box.put('after', 4);
      expect(backend.data, {'after': 4});
      await box.close();
    },
  );

  test(
    'rejected add/addAll do not advance keys while clear is pending',
    () async {
      final backend = FixtureBackend();
      final box = await eager(backend);
      expect(await box.add('old'), 0);
      final gate = Completer<void>();
      backend.nextClearGate = gate;
      final clearing = box.clear();
      try {
        expect(await rejectedByBarrier(box.add('forbidden')), isTrue);
        expect(
          await rejectedByBarrier(box.addAll(['forbidden-a', 'forbidden-b'])),
          isTrue,
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
        await clearing;
      }
      expect(await box.add('after'), 0);
      expect(box.get(0), 'after');
      expect(backend.data, {0: 'after'});
      await box.close();
    },
  );

  test(
    'lazy box also blocks clear/write overlap and preserves retry',
    () async {
      final backend = FixtureBackend();
      final box = await lazy(backend);
      await box.put('old', 1);
      final gate = Completer<void>();
      backend.nextClearGate = gate;
      final clearing = box.clear();
      try {
        expect(await rejectedByBarrier(box.put('late', 2)), isTrue);
        expect(await rejectedByBarrier(box.delete('old')), isTrue);
        expect(await rejectedByBarrier(box.add('late')), isTrue);
        expect(await box.get('old'), 1);
        expect(backend.data, {'old': 1});
      } finally {
        if (!gate.isCompleted) gate.complete();
        await clearing;
      }
      expect(box.isEmpty, isTrue);
      await box.put('after', 2);
      expect(await box.get('after'), 2);
      expect(backend.data, {'after': 2});
      await box.close();
    },
  );

  test('lazy clear waits for an earlier pending write', () async {
    final backend = FixtureBackend();
    final box = await lazy(backend);
    final gate = Completer<void>();
    backend.nextWriteGate = gate;
    final writing = box.put('first', 1);
    final clearing = box.clear();
    try {
      await Future<void>.delayed(Duration.zero);
      expect(backend.clears, 0);
      expect(await rejectedByBarrier(box.put('late', 2)), isTrue);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await writing;
      await clearing;
    }
    expect(box.isEmpty, isTrue);
    expect(backend.data, isEmpty);
    await box.close();
  });

  test('clear waits for every prior write, not only the first', () async {
    final backend = FixtureBackend();
    final box = await eager(backend);
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    backend.nextWriteGate = firstGate;
    final first = box.put('first', 1);
    backend.nextWriteGate = secondGate;
    final second = box.put('second', 2);
    final clearing = box.clear();
    try {
      firstGate.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(backend.clears, 0);
      expect(await rejectedByBarrier(box.put('late', 3)), isTrue);
    } finally {
      if (!firstGate.isCompleted) firstGate.complete();
      if (!secondGate.isCompleted) secondGate.complete();
      await first;
      await second;
      await clearing;
    }
    expect(box.isEmpty, isTrue);
    expect(backend.data, isEmpty);
    await box.close();
  });

  test(
    'failed clear keeps previous integer allocation after rejected adds',
    () async {
      final backend = FixtureBackend();
      final box = await eager(backend);
      await box.put(8, 'old');
      final gate = Completer<void>();
      backend.nextClearGate = gate;
      backend.failClear = true;
      final clearing = box.clear();
      final expectedError = expectLater(clearing, throwsStateError);
      try {
        expect(await rejectedByBarrier(box.add('blocked')), isTrue);
        expect(
          await rejectedByBarrier(box.addAll(['blocked-1', 'blocked-2'])),
          isTrue,
        );
        expect(() => box.putAt(0, 'blocked'), throwsA(isA<HiveError>()));
        expect(() => box.deleteAt(0), throwsA(isA<HiveError>()));
      } finally {
        if (!gate.isCompleted) gate.complete();
        await expectedError;
      }
      expect(await box.add('after'), 9);
      expect(box.toMap(), {8: 'old', 9: 'after'});
      expect(backend.data, {8: 'old', 9: 'after'});
      await box.close();
    },
  );

  test('real temporary VM files stay consistent on clear and retry', () async {
    final dir = await Directory.systemTemp.createTemp(
      'fitness_clear_interlock_',
    );
    final hive = HiveImpl()..init(dir.path);
    Box<dynamic>? box;
    LazyBox<dynamic>? lazyBox;
    try {
      box = await hive.openBox<dynamic>('synthetic_clear_disk');
      await box.put('old', 1);
      final clear = box.clear();
      final overlap = rejectedByBarrier(box.put('late', 2));
      expect(await overlap, isTrue);
      await clear;
      await box.put('after', 3);
      await box.close();
      box = await hive.openBox<dynamic>('synthetic_clear_disk');
      expect(box.toMap(), {'after': 3});
      await box.close();
      box = null;

      lazyBox = await hive.openLazyBox<dynamic>('synthetic_lazy_disk');
      await lazyBox.put('old', 1);
      final lazyClear = lazyBox.clear();
      final lazyOverlap = rejectedByBarrier(lazyBox.put('late', 2));
      expect(await lazyOverlap, isTrue);
      await lazyClear;
      await lazyBox.put('after', 4);
      await lazyBox.close();
      lazyBox = await hive.openLazyBox<dynamic>('synthetic_lazy_disk');
      expect(lazyBox.length, 1);
      expect(await lazyBox.get('after'), 4);
      expect(await lazyBox.get('old'), isNull);
    } finally {
      if (box != null && box.isOpen) await box.close();
      if (lazyBox != null && lazyBox.isOpen) await lazyBox.close();
      await dir.delete(recursive: true);
    }
  });
}
