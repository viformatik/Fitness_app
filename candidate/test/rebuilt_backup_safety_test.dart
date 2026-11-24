import 'dart:convert';
import 'dart:typed_data';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/backup_delivery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const water = 'water_intake_2026-10-25';
  const steps = 'steps_2026-10-25';

  group('import preview', () {
    test('counts added, changed, deleted and unchanged documents', () {
      final preview = previewImportDocuments(
        {water: 800, steps: 300},
        {water: 250, 'recipes': '[]'},
      );
      expect(preview.added, 1);
      expect(preview.changed, 1);
      expect(preview.deleted, 1);
      expect(preview.unchanged, 0);
      expect(preview.isEmpty, isFalse);
      expect(preview.removesDocuments, isTrue);
      expect(
        preview.summary,
        'Добавлено документов: 1. Изменено: 1. '
        'Удалено: 1. Без изменений: 0.',
      );
      // The summary is counts-only: no document key or value leaks into UI.
      expect(preview.summary.contains(water), isFalse);
      expect(preview.summary.contains('800'), isFalse);
    });

    test('identical sets are empty and do not need removal consent', () {
      final current = {water: 250, steps: 100};
      final preview = previewImportDocuments(current, current);
      expect(preview.isEmpty, isTrue);
      expect(preview.removesDocuments, isFalse);
      expect(preview.deleted, 0);
    });
  });

  group('review guard', () {
    test('detects a changed file, diary or account', () {
      final guard = ImportReviewGuard(
        documents: 'file-1',
        diary: 'diary-1',
        account: 'user-1',
      );
      expect(
        guard.staleReason(
          documents: 'file-1',
          diary: 'diary-1',
          account: 'user-1',
        ),
        isNull,
      );
      expect(
        guard.staleReason(
          documents: 'file-2',
          diary: 'diary-1',
          account: 'user-1',
        ),
        contains('Файл копии'),
      );
      expect(
        guard.staleReason(
          documents: 'file-1',
          diary: 'diary-2',
          account: 'user-1',
        ),
        contains('Дневник'),
      );
      expect(
        guard.staleReason(
          documents: 'file-1',
          diary: 'diary-1',
          account: 'user-2',
        ),
        contains('Аккаунт'),
      );
    });

    test('fingerprints are deterministic and order-independent', () {
      expect(
        documentsFingerprint({water: 250, steps: 1}),
        documentsFingerprint({steps: 1, water: 250}),
      );
      expect(
        documentsFingerprint({water: 250}),
        isNot(documentsFingerprint({water: 800})),
      );
    });
  });

  group('parseBackupDocuments', () {
    test('parses JSON exactly as the importer and rejects unknown keys', () {
      final text = jsonEncode({
        'app': 'fitness_tracker',
        'version': 2,
        'data': {water: 250},
      });
      expect(parseBackupDocuments(text), {water: 250});
      expect(
        parseBackupDocuments(jsonEncode({
          'app': 'fitness_tracker',
          'data': {'not_an_app_key': 1},
        })),
        isNull,
      );
      expect(() => parseBackupDocuments('not json'), throwsFormatException);
    });
  });

  group('removal confirmation', () {
    testWidgets('asks separately before an import that deletes documents',
        (tester) async {
      var confirmed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              confirmed = await confirmImportRemovals(
                tester.element(find.byType(ElevatedButton)),
                const ImportPreview(
                  added: 0,
                  changed: 0,
                  deleted: 2,
                  unchanged: 0,
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить локальные записи?'), findsOneWidget);
      expect(find.text('Удалить и импортировать'), findsOneWidget);
      await tester.tap(find.text('Удалить и импортировать'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    });

    testWidgets('cancelling keeps the diary untouched', (tester) async {
      var confirmed = true;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              confirmed = await confirmImportRemovals(
                tester.element(find.byType(ElevatedButton)),
                const ImportPreview(
                  added: 0,
                  changed: 0,
                  deleted: 1,
                  unchanged: 0,
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(confirmed, isFalse);
    });
  });

  group('backup delivery', () {
    final bytes = Uint8List.fromList(utf8.encode('synthetic'));
    const name = 'fitness_synthetic.json';

    test('a working share sheet is used first', () async {
      var downloads = 0;
      final result = await deliverBackupFile(
        bytes,
        fileName: name,
        mimeType: 'application/json',
        share: (_, fileName, mimeType, origin) async {},
        download: (_, _, _) async {
          downloads++;
          return true;
        },
      );
      expect(result, BackupDelivery.shared);
      expect(downloads, 0);
    });

    test('any share failure falls back to a real browser download', () async {
      final result = await deliverBackupFile(
        bytes,
        fileName: name,
        mimeType: 'application/json',
        share: (_, _, _, _) async => throw StateError('no navigator.canShare'),
        download: (_, fileName, mimeType) async => true,
      );
      expect(result, BackupDelivery.downloaded);
    });

    test('neither path working is reported as failure, not success', () async {
      final result = await deliverBackupFile(
        bytes,
        fileName: name,
        mimeType: 'application/json',
        share: (_, _, _, _) async => throw StateError('share failed'),
        download: (_, _, _) async => false,
      );
      expect(result, BackupDelivery.failed);
    });
  });
}
