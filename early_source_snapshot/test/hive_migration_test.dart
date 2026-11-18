import 'dart:convert';
import 'dart:io';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Real Hive: migrate once, reopen, persist, clear without resurrecting old preferences',
    () async {
      final directory = await Directory.systemTemp.createTemp('fitness_hive_');
      LocalPreferences.memoryForTests = false;
      LocalPreferences.directoryForTests = directory.path;
      SharedPreferences.setMockInitialValues({
        'food_entries_2026-10-25': jsonEncode([]),
        'water_intake_2026-10-25': 250,
        'supabase.auth.token': 'must not be migrated',
      });
      try {
        var store = await LocalPreferences.open();
        expect(store.getInt('water_intake_2026-10-25'), 250);
        expect(store.get('supabase.auth.token'), isNull);
        await store.setInt('water_intake_2026-10-25', 750);
        await store.setString('smart_settings', jsonEncode({'theme': 'oled'}));
        await store.setString('_ai_favorites_test', 'local-favorite');
        await LocalPreferences.close();
        store = await LocalPreferences.open();
        expect(store.getInt('water_intake_2026-10-25'), 750);
        expect(store.decoded('smart_settings'), {'theme': 'oled'});
        await store.clear(includeLocalAi: false);
        await LocalPreferences.close();
        store = await LocalPreferences.open();
        expect(store.snapshot(), isEmpty);
        expect(store.getInt('water_intake_2026-10-25'), isNull);
        expect(store.getString('_ai_favorites_test'), 'local-favorite');
        await store.clear();
        await LocalPreferences.close();
        store = await LocalPreferences.open();
        expect(store.getString('_ai_favorites_test'), isNull);
        expect(
          (await SharedPreferences.getInstance()).getInt(
            'water_intake_2026-10-25',
          ),
          250,
        );
      } finally {
        await LocalPreferences.close();
        LocalPreferences.directoryForTests = null;
        await directory.delete(recursive: true);
      }
    },
  );
}
