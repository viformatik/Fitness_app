import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show SemanticsAction;

import 'package:fitness_tracker/smart/activity_trends.dart';
import 'package:fitness_tracker/smart/activity_trends_ui.dart';
import 'package:fitness_tracker/smart/journal_overview.dart';
import 'package:fitness_tracker/smart/sleep.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String sleep(String day, int minutes) =>
    encodeSleepDay(SleepDay(day: day, minutes: minutes));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final from = DateTime(2026, 10, 24), to = DateTime(2026, 10, 30);
  final docs = <String, Object?>{
    'steps_2026-10-24': 0,
    'steps_2026-10-25': 1000,
    'steps_2026-10-26': 'wrong type',
    'steps_2026-10-28': null,
    'steps_2026-10-31': 9999,
    'steps_2026-99-99': 4,
    'sleep_day_2026-10-24': sleep('2026-10-24', 0),
    'sleep_day_2026-10-25': sleep('2026-10-25', 480),
    'sleep_day_2026-10-26': sleep('2026-10-25', 600), // wrong day
    'sleep_day_2026-10-27': '{broken',
    'sleep_day_2026-10-29': null,
    'sleep_day_2026-11-01': sleep('2026-11-01', 600),
  };

  test(
    'actual zero, missing, tombstone, unreadable and bad dates remain distinct',
    () {
      final original = jsonEncode(docs);
      final steps = buildActivitySeries(docs, from, to, ActivityMetric.steps);
      expect(steps.calendarDays, 7);
      expect(steps.buckets, hasLength(7));
      expect(steps.recordedDays, 2);
      expect(steps.unreadableDays, 1);
      expect(steps.unassignedDocuments, 1);
      expect(steps.average, 500);
      expect(steps.buckets[0].average, 0);
      expect(steps.buckets[0].missingDays, 0);
      expect(steps.buckets[1].average, 1000);
      expect(steps.buckets[2].average, isNull);
      expect(steps.buckets[2].unreadableDays, 1);
      expect(steps.buckets[3].missingDays, 1);
      expect(steps.buckets[4].missingDays, 1); // tombstone

      final sleepTrend = buildActivitySeries(
        docs,
        from,
        to,
        ActivityMetric.sleep,
      );
      expect(sleepTrend.recordedDays, 2);
      expect(sleepTrend.unreadableDays, 2);
      expect(sleepTrend.average, 240); // minutes, two actual records, not seven
      expect(sleepTrend.buckets.first.average, 0);
      expect(sleepTrend.buckets[2].unreadableDays, 1);
      expect(sleepTrend.buckets[3].unreadableDays, 1);
      expect(sleepTrend.buckets[5].missingDays, 1);
      expect(jsonEncode(docs), original);
      expect(() => steps.buckets.clear(), throwsUnsupportedError);
    },
  );

  test(
    'unknown sleep schema and too-large or negative steps are not calculated',
    () {
      final extended =
          jsonDecode(sleep('2026-10-24', 450)) as Map<String, dynamic>;
      extended['futureField'] = 'preserve';
      final bad = {
        'sleep_day_2026-10-24': jsonEncode(extended),
        'steps_2026-10-24': -1,
        'steps_2026-10-25': maxChartStepsPerDay + 1,
        'steps_2026-10-26': maxChartStepsPerDay,
      };
      final s = buildActivitySeries(bad, from, to, ActivityMetric.sleep);
      expect(s.average, isNull);
      expect(s.unreadableDays, 1);
      final st = buildActivitySeries(bad, from, to, ActivityMetric.steps);
      expect(st.unreadableDays, 2);
      expect(st.recordedDays, 1);
      expect(st.total, maxChartStepsPerDay);
      final overview = summarizeJournal(bad, from, to);
      expect(overview.sections['steps']!['recordedDays'], 1);
      expect(overview.sections['steps']!['totalSteps'], maxChartStepsPerDay);
      expect(overview.unreadableDocuments, 2);
      expect(bad['steps_2026-10-25'], maxChartStepsPerDay + 1);
    },
  );

  test(
    'grouping uses UTC calendar days, weighted averages, leap days and exact endpoints',
    () {
      final first = DateTime(2024, 2, 27), last = DateTime(2024, 4, 2);
      final entries = {
        'steps_2024-02-27': 0,
        'steps_2024-02-28': 300,
        'steps_2024-02-29': 600,
        'steps_2024-03-31': 900,
        'steps_2024-04-02': 1200,
      };
      final s = buildActivitySeries(entries, first, last, ActivityMetric.steps);
      expect(s.calendarDays, 36);
      expect(s.buckets.length, lessThanOrEqualTo(14));
      expect(s.buckets.first.firstDay, DateTime.utc(2024, 2, 27));
      expect(s.buckets.last.lastDay, DateTime.utc(2024, 4, 2));
      expect(s.buckets.fold<int>(0, (n, b) => n + b.calendarDays), 36);
      expect(s.buckets.first.total, 900);
      expect(s.buckets.first.recordedDays, 3);
      expect(s.buckets.first.average, 300);
      expect(s.average, 600); // all records, not the unweighted mean of buckets
      for (var i = 1; i < s.buckets.length; i++) {
        expect(
          s.buckets[i].firstDay.difference(s.buckets[i - 1].lastDay).inDays,
          1,
        );
      }
      final autumn = buildActivitySeries(
        {},
        DateTime(2026, 10, 24),
        DateTime(2026, 10, 27),
        ActivityMetric.steps,
      );
      expect(autumn.buckets.map((b) => b.firstDay.day), [24, 25, 26, 27]);
      expect(autumn.average, isNull);
    },
  );

  test('long sparse ranges are bounded and invalid arguments rejected', () {
    final s = buildActivitySeries(
      {'steps_1900-01-01': 10, 'steps_1999-12-31': 30},
      DateTime(1900, 1, 1),
      DateTime(1999, 12, 31),
      ActivityMetric.steps,
    );
    expect(s.calendarDays, 36524);
    expect(s.buckets.length, lessThanOrEqualTo(14));
    expect(s.recordedDays, 2);
    expect(s.average, 20);
    expect(s.buckets.last.lastDay, DateTime.utc(1999, 12, 31));
    expect(
      () => buildActivitySeries({}, to, from, ActivityMetric.steps),
      throwsArgumentError,
    );
    expect(
      () => buildActivitySeries(
        {},
        from,
        to,
        ActivityMetric.steps,
        maxBuckets: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => buildActivitySeries(
        {},
        DateTime(1800),
        DateTime(2000),
        ActivityMetric.steps,
      ),
      throwsArgumentError,
    );
  });

  test(
    'all groups partition sparse periods without losing or duplicating data',
    () {
      final random = math.Random(47);
      for (final days in [1, 7, 14, 15, 28, 29, 31, 90, 365]) {
        final first = DateTime.utc(2024, 2, 20);
        final last = first.add(Duration(days: days - 1));
        final values = <String, Object?>{};
        var recorded = 0, unreadable = 0, total = 0;
        for (var i = 0; i < days; i++) {
          final day = first.add(Duration(days: i));
          final key = 'steps_${sleepDateKey(day)}';
          final choice = random.nextInt(4);
          if (choice == 0) continue;
          if (choice == 1) {
            values[key] = 'broken';
            unreadable++;
          } else {
            final value = random.nextInt(5000);
            values[key] = value;
            recorded++;
            total += value;
          }
        }
        for (final limit in [1, 2, 14, 100]) {
          final s = buildActivitySeries(
            values,
            first,
            last,
            ActivityMetric.steps,
            maxBuckets: limit,
          );
          expect(s.buckets.length, lessThanOrEqualTo(limit));
          expect(s.recordedDays, recorded);
          expect(s.unreadableDays, unreadable);
          expect(s.total, total);
          expect(s.buckets.fold<int>(0, (n, b) => n + b.calendarDays), days);
          expect(
            s.buckets.fold<int>(0, (n, b) => n + b.recordedDays),
            recorded,
          );
          expect(
            s.buckets.fold<int>(0, (n, b) => n + b.unreadableDays),
            unreadable,
          );
          expect(s.buckets.fold<int>(0, (n, b) => n + b.total), total);
          for (final b in s.buckets) {
            expect(
              b.recordedDays + b.unreadableDays + b.missingDays,
              b.calendarDays,
            );
          }
        }
      }
    },
  );

  test(
    'overview derives both series from the snapshot without expanding the AI payload',
    () {
      final overview = summarizeJournal(docs, from, to);
      expect(overview.stepsTrend.average, 500);
      expect(overview.sleepTrend.average, 240);
      final request = jsonEncode(overview.request({'steps'}, ''));
      expect(request, isNot(contains('sleep')));
      expect(request, isNot(contains('Trend')));
      expect(
        request,
        isNot(contains('2026-10-25')),
      ); // individual day not transmitted
      expect(request, isNot(contains('480')));
    },
  );

  Future<void> pumpPanel(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ActivityTrendPanel(
              steps: buildActivitySeries(docs, from, to, ActivityMetric.steps),
              sleep: buildActivitySeries(docs, from, to, ActivityMetric.sleep),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('narrow portrait: controls, recorded zero, missing and sleep', (
    tester,
  ) async {
    await pumpPanel(tester, const Size(320, 700));
    expect(find.text('Графики активности'), findsOneWidget);
    expect(find.textContaining('среднее ≈ 500 шагов'), findsOneWidget);
    expect(
      find.textContaining('Не рассчитано записей в периоде: 1'),
      findsOneWidget,
    );
    expect(find.textContaining('30.10.2026: нет записей'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Предыдущий период графика'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byTooltip('Предыдущий период графика'));
      await tester.pump();
    }
    expect(
      find.textContaining('24.10.2026: 0 шагов; записано 1 из 1'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Сон'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сон'));
    await tester.pumpAndSettle();
    expect(find.textContaining('среднее ≈ 4 ч 0 мин'), findsOneWidget);
    expect(
      find.textContaining('24.10.2026: 0 ч 0 мин; записано 1 из 1'),
      findsOneWidget,
    );
    expect(find.textContaining('не отправляется в ИИ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow screen with enlarged text remains usable', (
    tester,
  ) async {
    await pumpPanel(tester, const Size(320, 700), textScale: 1.5);
    await tester.ensureVisible(find.byTooltip('Предыдущий период графика'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Предыдущий период графика'));
    await tester.pump();
    expect(find.textContaining('29.10.2026: нет записей'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen reader can move between chart intervals', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpPanel(tester, const Size(320, 700));
    await tester.ensureVisible(find.byKey(const ValueKey('activityTrendPlot')));
    await tester.pumpAndSettle();
    final node = tester.getSemantics(
      find.byKey(const ValueKey('activityTrendPlot')),
    );
    expect(node.getSemanticsData().label, contains('График: Шаги'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.decrease);
    await tester.pump();
    expect(find.textContaining('29.10.2026: нет записей'), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets(
    'landscape: chart can be tapped and arrow buttons remain accessible',
    (tester) async {
      await pumpPanel(tester, const Size(900, 320));
      final paint = find.byKey(const ValueKey('activityTrendPlot'));
      await tester.ensureVisible(paint);
      await tester.pumpAndSettle();
      final bounds = tester.getRect(paint);
      await tester.tapAt(
        Offset(bounds.left + bounds.width / 14, bounds.center.dy),
      );
      await tester.pump();
      expect(find.textContaining('24.10.2026: 0 шагов'), findsOneWidget);
      final next = find.byTooltip('Следующий период графика');
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      await tester.tap(next);
      await tester.pump();
      expect(find.textContaining('25.10.2026: 1 000 шагов'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
