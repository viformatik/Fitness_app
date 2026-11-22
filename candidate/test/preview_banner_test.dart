import 'package:fitness_tracker/smart/preview_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('synthetic candidate shows its warning by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => IsolatedPreviewBanner(child: child!),
        home: const Scaffold(body: Text('Дневник')),
      ),
    );
    expect(find.text('Дневник'), findsOneWidget);
    expect(find.textContaining('ТЕСТОВАЯ ВЕРСИЯ'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(1280, 800),
  ]) {
    testWidgets('test banner is legible and does not block the app at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              IsolatedPreviewBanner(enabled: true, child: child!),
          home: Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => presses++,
                child: const Text('Кнопка дневника'),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('ТЕСТОВАЯ ВЕРСИЯ'), findsOneWidget);
      expect(find.textContaining('Только вымышленные записи'), findsOneWidget);
      expect(
        find.textContaining('Не связана с вашим рабочим дневником'),
        findsOneWidget,
      );
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('ТЕСТОВАЯ ВЕРСИЯ')), findsOneWidget);
      semantics.dispose();
      await tester.tap(find.text('Кнопка дневника'));
      expect(presses, 1);
      expect(tester.takeException(), isNull);
      final banner = tester.getRect(find.byType(IsolatedPreviewBanner));
      expect(banner.width, size.width);
    });
  }
}
