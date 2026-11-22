import 'package:fitness_tracker/legacy.dart';
import 'package:fitness_tracker/smart/activity_trends_ui.dart';
import 'package:fitness_tracker/smart/journal_overview_ui.dart';
import 'package:fitness_tracker/smart/local_store.dart';
import 'package:fitness_tracker/smart/sleep.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'overview periods, custom dates and local refresh use persisted data',
    (tester) async {
      LocalPreferences.memoryForTests = true;
      final day = DateTime(2026, 10, 30);
      final sleepRaw = encodeSleepDay(
        const SleepDay(day: '2026-10-25', minutes: 480),
      );
      SharedPreferences.setMockInitialValues({
        'steps_2026-10-23': 7777,
        'steps_2026-10-24': 0,
        'steps_2026-10-25': 1000,
        'steps_2026-10-30': 3000,
        'sleep_day_2026-10-25': sleepRaw,
      });
      final p = AppDataProvider();
      await p.init();
      await p.setSelectedDate(day);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppDataProvider>.value(
          value: p,
          child: const MaterialApp(
            locale: Locale('ru'),
            supportedLocales: [Locale('ru'), Locale('en')],
            localizationsDelegates: [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: _OverviewHost(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> chart() async {
        await tester.scrollUntilVisible(
          find.byType(ActivityTrendPanel),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      Future<void> top() async {
        await tester.drag(find.byType(ListView).first, const Offset(0, 4000));
        await tester.pumpAndSettle();
      }

      await chart();
      expect(
        find.textContaining('среднее ≈ 1 333 шагов за 3 дн. с записью из 7'),
        findsOneWidget,
      );
      await top();
      await tester.tap(find.text('30 дней'));
      await tester.pumpAndSettle();
      await chart();
      expect(
        find.textContaining('среднее ≈ 2 944 шагов за 4 дн. с записью из 30'),
        findsOneWidget,
      );
      await top();
      await tester.tap(find.text('Выбрать период'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      final dialogFields = find.descendant(
        of: find.byType(DateRangePickerDialog),
        matching: find.byType(TextField),
      );
      expect(dialogFields, findsNWidgets(2));
      await tester.enterText(dialogFields.at(0), '24.10.2026');
      await tester.enterText(dialogFields.at(1), '26.10.2026');
      await tester.tap(find.text('ОК'));
      await tester.pumpAndSettle();
      await chart();
      expect(
        find.textContaining('среднее ≈ 500 шагов за 2 дн. с записью из 3'),
        findsOneWidget,
      );
      await tester.tap(find.text('Сон'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('среднее ≈ 8 ч 0 мин за 1 дн. с записью из 3'),
        findsOneWidget,
      );

      await p.setSelectedDate(DateTime(2026, 10, 26));
      await p.setSteps(2500);
      await p.storage.pendingMutations;
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await chart();
      await tester.tap(
        find.descendant(
          of: find.byType(ActivityTrendPanel),
          matching: find.text('Шаги'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('среднее ≈ 1 167 шагов за 3 дн. с записью из 3'),
        findsOneWidget,
      );
      expect(p.storage.local.getString('sleep_day_2026-10-25'), sleepRaw);
      expect(p.storage.local.getInt('steps_2026-10-24'), 0);
      expect(p.storage.local.getInt('steps_2026-10-26'), 2500);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      p.dispose();
    },
  );
}

class _OverviewHost extends StatelessWidget {
  const _OverviewHost();
  @override
  Widget build(BuildContext context) =>
      JournalOverviewScreen(provider: context.read<AppDataProvider>());
}
