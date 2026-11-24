import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../legacy.dart'
    show
        AppTheme,
        BackupReview,
        BackupReviewIssue,
        StorageService,
        dayKey,
        reviewBackupFile;
import 'backup_delivery.dart';
import 'preview_banner.dart';

/// A deliberately read-only fallback when provider initialization fails.
/// It is not a repair routine or a guarantee that an export is restorable.
class StartupRecoveryApp extends StatelessWidget {
  final StorageService storage;
  final bool canReadStorage;
  const StartupRecoveryApp({
    super.key,
    required this.storage,
    required this.canReadStorage,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Fitness Smart',
    debugShowCheckedModeBanner: false,
    builder: (context, child) => IsolatedPreviewBanner(
      enabled: false,
      child: child ?? const SizedBox.shrink(),
    ),
    theme: AppTheme.darkTheme,
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: StartupRecoveryScreen(
      storage: storage,
      canReadStorage: canReadStorage,
    ),
  );
}

class StartupRecoveryScreen extends StatefulWidget {
  final StorageService storage;
  final bool canReadStorage;
  const StartupRecoveryScreen({
    super.key,
    required this.storage,
    required this.canReadStorage,
  });

  @override
  State<StartupRecoveryScreen> createState() => _StartupRecoveryScreenState();
}

class _StartupRecoveryScreenState extends State<StartupRecoveryScreen> {
  String? _snapshot;
  BackupReview? _review;
  String? _notice;
  bool _busy = false;

  Future<void> _prepare() async {
    if (!widget.canReadStorage || _busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      _snapshot = null;
      _review = null;
    });
    try {
      // exportData waits for admitted local writes and refuses unsupported
      // values or a pending import instead of silently dropping documents.
      // It still cannot fence other tabs, devices, or cloud changes.
      final data = await widget.storage.exportData();
      final snapshot = const JsonEncoder.withIndent('  ').convert(data);
      final review = reviewBackupFile(snapshot);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _review = review;
      });
    } catch (_) {
      // Never include exception messages or record content in the UI/logs.
      if (!mounted) return;
      setState(() {
        _notice =
            'Не удалось подготовить копию. Не очищайте данные приложения; '
            'может понадобиться ручное восстановление.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    final snapshot = _snapshot;
    if (snapshot == null || _busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final box = context.findRenderObject() as RenderBox?;
      // A successful share call alone does not prove that a file was saved.
      final delivered = await deliverBackupFile(
        Uint8List.fromList(utf8.encode(snapshot)),
        fileName:
            'fitness_recovery_unverified_${dayKey(DateTime.now())}.json',
        mimeType: 'application/json',
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      );
      if (!mounted) return;
      setState(() {
        // Keep an undelivered snapshot so the user can retry explicitly.
        if (delivered != BackupDelivery.failed) {
          _snapshot = null;
          _review = null;
        }
        _notice = switch (delivered) {
          BackupDelivery.shared =>
            'Файл передан в систему обмена. Проверьте, появился ли файл, '
                'и храните его в защищённом месте.',
          BackupDelivery.downloaded =>
            'Файл сохранён как загрузка браузера. Проверьте папку загрузок '
                'и храните его в защищённом месте.',
          BackupDelivery.failed =>
            'Не удалось передать файл. Можно повторить попытку; '
                'не очищайте данные приложения.',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notice =
            'Не удалось передать файл. Можно повторить попытку; '
            'не очищайте данные приложения.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _reviewMessage(BackupReview review) => switch (review.issue) {
    BackupReviewIssue.none =>
      'Формат и размер прошли предварительную проверку, но полнота и '
          'восстановление не проверены.',
    BackupReviewIssue.tooLarge =>
      'Файл больше 20 МиБ: импорт файла в текущей версии его не примет.',
    BackupReviewIssue.changedDocuments =>
      'Содержимое не прошло предварительную проверку соответствия.',
    BackupReviewIssue.invalid =>
      'Некоторые документы не прошли проверку импортёра. '
          'Импорт этой копии может быть отклонён.',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Безопасный запуск')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Не удалось открыть дневник',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Причина может быть в записи, хранилище или другой ошибке. '
                  'Дневник не показан как пустой; на этом экране изменения '
                  'дневника и синхронизация не запускаются. Другие вкладки и '
                  'устройства могут продолжать изменять данные.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Не очищайте данные браузера или приложения и не импортируйте '
                  'файл поверх единственной копии дневника. Не удаляйте '
                  'приложение до восстановления данных.',
                ),
                const SizedBox(height: 16),
                if (!widget.canReadStorage)
                  const Text(
                    'Безопасный доступ к локальному хранилищу не подтверждён. '
                    'На этом экране нельзя подготовить копию; может '
                    'понадобиться ручное восстановление.',
                  )
                else ...[
                  const Text(
                    'Можно попробовать подготовить непроверенный JSON-снимок '
                    'из доступных записей. Он содержит личные данные; '
                    'локальные черновики и согласие ИИ, данные входа и облако '
                    'в него не входят. Снимок не является доказанной копией: '
                    'он отражает момент подготовки и может быть неполным. '
                    'При сохранении система или выбранное приложение может '
                    'создать временный файл.',
                  ),
                  const SizedBox(height: 12),
                  if (_snapshot == null)
                    FilledButton.icon(
                      onPressed: _busy ? null : _prepare,
                      icon: const Icon(Icons.file_copy_outlined),
                      label: Text(_busy ? 'Подготовка…' : 'Подготовить копию'),
                    )
                  else ...[
                    Text(_reviewMessage(_review!)),
                    const SizedBox(height: 8),
                    const Text(
                      'Проверьте восстановление только в отдельном профиле. '
                      'Не отправляйте файл посторонним.',
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy ? null : _share,
                          icon: const Icon(Icons.save_alt),
                          label: const Text('Сохранить непроверенную копию'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _snapshot = null;
                                  _review = null;
                                  _notice = null;
                                }),
                          child: const Text('Отмена'),
                        ),
                      ],
                    ),
                  ],
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(_notice!)),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
