// Fake file picker and synthetic in-memory documents; no real user files.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/engine.dart' show exportCsv;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:fitness_tracker/smart/ui.dart' show BackupPanel;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FixturePicker extends FilePicker {
  PlatformFile? next;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    if (type != FileType.custom ||
        !withData ||
        allowMultiple ||
        !allowedExtensions!.contains('json') ||
        !allowedExtensions.contains('csv')) {
      throw StateError('Unexpected test picker parameters');
    }
    final file = next;
    return file == null ? null : FilePickerResult([file]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const water = 'water_intake_2026-10-25';
  const food = 'food_entries_2026-10-25';

  testWidgets(
    'file importer rejects invalid, oversized and malformed data before confirmation',
    (tester) async {
      late AppDataProvider provider;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        LocalPreferences.memoryForTests = true;
        LocalPreferences.directoryForTests = null;
        LocalPreferences.beforeWriteForTests = null;
        LocalPreferences.rejectWriteKeyForTests = null;
        LocalPreferences.clearImportRecoveryFailure();
        SmartRemote.instance.busy = false;
        provider = AppDataProvider();
        await provider.init();
        await provider.storage.local.setInt(water, 500);
        await provider.storage.local.setString(
          '_ai_consent_synthetic',
          'PRIVATE_FIXTURE_ONLY',
        );
      });
      final before = provider.storage.local.snapshot();
      final picker = FixturePicker();
      FilePicker.platform = picker;
      PlatformFile fromText(String name, String text) {
        final bytes = Uint8List.fromList(utf8.encode(text));
        return PlatformFile(name: name, size: bytes.length, bytes: bytes);
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: BackupPanel(provider: provider)),
          ),
        );
        Future<void> select(PlatformFile file) async {
          picker.next = file;
          await tester.tap(find.text('Импорт JSON / CSV'));
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pumpAndSettle();
        }

        await select(
          fromText(
            'synthetic-bad.json',
            jsonEncode({
              'app': 'fitness_tracker',
              'data': {water: 750, food: 'NOT_VALID_JSON'},
            }),
          ),
        );
        expect(find.text('Заменить всю локальную историю?'), findsNothing);
        expect(
          find.textContaining('Копия не прошла проверку импортёра'),
          findsOneWidget,
        );
        expect(provider.storage.local.snapshot(), before);
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        await select(
          fromText('synthetic-bad.csv', 'record_type,id,raw_json\r\n'),
        );
        expect(find.text('Заменить всю локальную историю?'), findsNothing);
        expect(
          find.textContaining('Копия не прошла проверку импортёра'),
          findsOneWidget,
        );
        expect(provider.storage.local.snapshot(), before);
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        // The platform reports a misleading size; the actual byte array must win.
        await select(
          PlatformFile(
            name: 'synthetic-large.json',
            size: 1,
            bytes: Uint8List(backupFileLimitBytes + 1),
          ),
        );
        expect(find.text('Заменить всю локальную историю?'), findsNothing);
        expect(find.textContaining('20 МиБ'), findsOneWidget);
        expect(provider.storage.local.snapshot(), before);
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        await select(
          PlatformFile(
            name: 'synthetic-utf8.json',
            size: 2,
            bytes: Uint8List.fromList([0xc3, 0x28]),
          ),
        );
        expect(find.text('Заменить всю локальную историю?'), findsNothing);
        expect(provider.storage.local.snapshot(), before);
        await tester.pump(const Duration(seconds: 7));
        await tester.pumpAndSettle();
        final valid = exportCsv({water: 750, food: '[]'});
        await select(fromText('synthetic-valid.csv', valid));
        expect(find.text('Заменить всю локальную историю?'), findsOneWidget);
        expect(provider.storage.local.snapshot(), before);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(provider.storage.local.snapshot(), before);
        await select(fromText('synthetic-valid.csv', valid));
        await tester.runAsync(() async {
          await tester.tap(find.text('Заменить'));
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await provider.storage.pendingMutations.timeout(
            const Duration(seconds: 3),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(provider.storage.local.getInt(water), 750);
        expect(provider.storage.local.getString(food), '[]');
        expect(
          provider.storage.local.getString('_ai_consent_synthetic'),
          'PRIVATE_FIXTURE_ONLY',
        );
        expect(provider.storage.local.hasImportBackup, isTrue);
        expect(provider.storage.local.importSyncPaused, isTrue);
        expect(picker.calls, 6);
        await tester.pump();
      } finally {
        await tester.runAsync(() async {
          provider.dispose();
          LocalPreferences.beforeWriteForTests = null;
          LocalPreferences.onAppWrite = null;
          await LocalPreferences.close();
          SmartRemote.instance.busy = false;
          LocalPreferences.memoryForTests = false;
        });
      }
    },
  );
}
