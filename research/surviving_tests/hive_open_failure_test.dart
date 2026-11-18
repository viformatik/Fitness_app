// Synthetic Hive filesystem paths only; not the app's or user's database.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/src/hive_impl.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a sole failed open reports to its caller, not twice to the zone',
    () async {
      final root = await Directory.systemTemp.createTemp('fitness_hive_open_');
      final invalid = File('${root.path}/not_a_directory');
      await invalid.writeAsString('SYNTHETIC');
      final stray = <Object>[];
      final finished = Completer<void>();
      Object? callerError;
      try {
        runZonedGuarded(() async {
          final hive = HiveImpl()..init(invalid.path);
          try {
            await hive.openBox<dynamic>('synthetic_failure');
          } catch (error) {
            callerError = error;
          }
          // Allow any orphaned future error to reach this guarded zone.
          await Future<void>.delayed(const Duration(milliseconds: 80));
          finished.complete();
        }, (error, _) => stray.add(error));
        await finished.future.timeout(const Duration(seconds: 10));
        expect(callerError, isA<FileSystemException>());
        expect(stray, isEmpty, reason: 'The coordination future has no caller');
        expect(await invalid.readAsString(), 'SYNTHETIC');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'concurrent open waiters receive failure and a later retry can open',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fitness_hive_waiters_',
      );
      final invalid = File('${root.path}/not_a_directory');
      await invalid.writeAsString('SYNTHETIC');
      final hive = HiveImpl()..init(invalid.path);
      Future<Object?> observe(Future<Object?> input) => input.then<Object?>(
        (_) => null,
        onError: (Object e, StackTrace _) => e,
      );
      try {
        final first = observe(hive.openBox<dynamic>('synthetic_waiters'));
        final second = observe(hive.openBox<dynamic>('synthetic_waiters'));
        final errors = await Future.wait([first, second]);
        expect(errors[0], isA<FileSystemException>());
        expect(errors[1], isA<FileSystemException>());
        expect(hive.isBoxOpen('synthetic_waiters'), isFalse);
        hive.init('${root.path}/valid');
        final box = await hive.openBox<dynamic>('synthetic_waiters');
        await box.put('only_synthetic', 42);
        await box.close();
        final reopened = await hive.openBox<dynamic>('synthetic_waiters');
        expect(reopened.get('only_synthetic'), 42);
        await reopened.close();
        expect(await invalid.readAsString(), 'SYNTHETIC');
      } finally {
        await hive.close();
        await root.delete(recursive: true);
      }
    },
  );
}
