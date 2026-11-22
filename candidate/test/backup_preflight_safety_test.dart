// Synthetic-only tests. No user diary, server, account, or network is used.
import 'dart:convert';

import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/csv_reader.dart';
import 'package:fitness_tracker/smart/engine.dart' show exportCsv;
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const water = 'water_intake_2026-10-25';
  const food = 'food_entries_2026-10-25';

  test(
    'synthetic malformed document exports but importer rejects it safely',
    () async {
      LocalPreferences.memoryForTests = true;
      LocalPreferences.directoryForTests = null;
      LocalPreferences.beforeWriteForTests = null;
      LocalPreferences.rejectWriteKeyForTests = null;
      LocalPreferences.clearImportRecoveryFailure();
      SmartRemote.instance.busy = false;
      SharedPreferences.setMockInitialValues({});
      final provider = AppDataProvider();
      try {
        await provider.init();
        final local = provider.storage.local;
        await local.setInt(water, 750);
        await local.setString(food, 'SYNTHETIC_NOT_VALID_JSON');
        await local.setString('_ai_consent_synthetic', 'PRIVATE_FIXTURE_ONLY');
        final before = local.snapshot();
        final payload = await provider.storage.exportData();
        expect((payload['data'] as Map)[food], 'SYNTHETIC_NOT_VALID_JSON');
        final raw = jsonEncode(payload);
        expect(raw, isNot(contains('PRIVATE_FIXTURE_ONLY')));
        expect(reviewBackupFile(raw).issue, BackupReviewIssue.invalid);
        expect(
          reviewBackupFile(
            exportCsv(Map<String, dynamic>.from(payload['data'] as Map)),
            csv: true,
          ).issue,
          BackupReviewIssue.invalid,
        );
        expect(
          await provider.importDataJson(raw),
          'Некорректная резервная копия. Данные не заменены.',
        );
        expect(local.snapshot(), before);
        expect(
          local.getString('_ai_consent_synthetic'),
          'PRIVATE_FIXTURE_ONLY',
        );
        expect(local.get(LocalPreferences.importJournalKey), isNull);
      } finally {
        provider.dispose();
        LocalPreferences.beforeWriteForTests = null;
        LocalPreferences.rejectWriteKeyForTests = null;
        LocalPreferences.clearImportRecoveryFailure();
        SmartRemote.instance.busy = false;
        LocalPreferences.memoryForTests = false;
      }
    },
  );

  group('non-mutating file preflight', () {
    final docs = <String, dynamic>{
      water: 0,
      food: '[]',
      'steps_2026-10-25': 1234,
      'workout_entries_2026-10-25': '[]',
      'workout_completed_2026-10-25': false,
      // Unknown JSON fields within a known document must remain byte-for-byte.
      'reminders': '{"enabled":false,"synthetic_extra":"чай, \\\"да\\\""}',
    };
    String envelope(Map<String, dynamic> data) =>
        jsonEncode({'app': 'fitness_tracker', 'version': 2, 'data': data});

    test(
      'valid JSON and CSV survive the same importer rules and exact rows',
      () {
        final json = envelope(docs);
        final csv = exportCsv(docs);
        expect(
          reviewBackupFile(json, expectedDocuments: docs).issue,
          BackupReviewIssue.none,
        );
        expect(
          reviewBackupFile(csv, csv: true, expectedDocuments: docs).issue,
          BackupReviewIssue.none,
        );
        expect(importCsv(csv), docs);
        expect((jsonDecode(json) as Map)['data'], docs);
        expect(reviewBackupFile(json).utf8Bytes, utf8.encode(json).length);
        expect(
          reviewBackupFile(csv, csv: true).utf8Bytes,
          utf8.encode(csv).length,
        );
      },
    );

    test('empty JSON remains allowed but CSV requires document rows', () {
      expect(reviewBackupFile(envelope({})).issue, BackupReviewIssue.none);
      expect(
        reviewBackupFile('record_type,id,raw_json\r\n', csv: true).issue,
        BackupReviewIssue.invalid,
      );
    });

    test('bad envelopes, keys, values and broken records are not approved', () {
      for (final raw in [
        '{invalid',
        jsonEncode({'app': 'other', 'data': docs}),
        jsonEncode({'app': 'fitness_tracker', 'data': []}),
        envelope({'_ai_consent_synthetic': 'PRIVATE_FIXTURE_ONLY'}),
        envelope({water: null}),
        envelope({water: -1}),
        envelope({water: '750'}),
        envelope({food: 'not-json'}),
        envelope({food: '[{"name":""}]'}),
        envelope({'gym_session_synthetic': '{}'}),
        envelope({'sleep_day_2026-10-25': '{}'}),
      ]) {
        expect(reviewBackupFile(raw).issue, BackupReviewIssue.invalid);
        expect(
          reviewBackupFile(raw).toString(),
          isNot(contains('PRIVATE_FIXTURE_ONLY')),
        );
      }
    });

    test(
      'CSV missing, duplicated, invalid or changed documents are rejected',
      () {
        final csv = exportCsv(docs);
        final sourceRows = csv.split('\r\n');
        final repeated = [...sourceRows, sourceRows[1]].join('\r\n');
        expect(
          reviewBackupFile(repeated, csv: true).issue,
          BackupReviewIssue.invalid,
        );
        expect(
          reviewBackupFile(
            csv,
            csv: true,
            expectedDocuments: {...docs, water: 500},
          ).issue,
          BackupReviewIssue.changedDocuments,
        );
        expect(
          reviewBackupFile(
            envelope(docs),
            expectedDocuments: {...docs, water: 500},
          ).issue,
          BackupReviewIssue.changedDocuments,
        );
        expect(
          reviewBackupFile('not,csv', csv: true).issue,
          BackupReviewIssue.invalid,
        );
      },
    );

    test(
      'streaming byte count matches UTF-8 for mixed and malformed Unicode',
      () {
        for (final text in [
          '',
          'abc',
          'Привет 💪',
          '\uD800',
          '\uDC00',
          '${'a' * 1023}💪я',
          '${'а' * 1024}\uD800end',
        ]) {
          expect(reviewBackupFile(text).utf8Bytes, utf8.encode(text).length);
        }
      },
    );

    test('20 MiB limit uses UTF-8 bytes, allowing the exact boundary', () {
      final small = envelope({water: 250});
      final padding = backupFileLimitBytes - utf8.encode(small).length;
      final exact = '$small${' ' * padding}';
      expect(exact.length, backupFileLimitBytes);
      expect(reviewBackupFile(exact).issue, BackupReviewIssue.none);
      expect(reviewBackupFile('$exact ').issue, BackupReviewIssue.tooLarge);
      // Fewer UTF-16 code units than the limit, but more UTF-8 bytes.
      final cyrillic = 'я' * (backupFileLimitBytes ~/ 2 + 1);
      final review = reviewBackupFile(cyrillic);
      expect(cyrillic.length, lessThan(backupFileLimitBytes));
      expect(review.utf8Bytes, backupFileLimitBytes + 2);
      expect(review.issue, BackupReviewIssue.tooLarge);
    });
  });
}
