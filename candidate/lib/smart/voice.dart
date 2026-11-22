import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'local_store.dart';

const voiceFallbackHint =
    'Если браузер не поддерживает диктовку, нажмите микрофон на клавиатуре '
    'телефона — распознанный текст появится в поле ввода.';

/// Chrome's Web Speech implementation does not enumerate all locales. Using
/// ru-RU directly works on Android Chrome; the old locale check falsely
/// reported "Russian recognition unavailable".
String resolveSpeechLocale({
  required bool web,
  List<String> locales = const [],
}) {
  if (web) return 'ru-RU';
  for (final raw in locales) {
    final normalized = raw.replaceAll('_', '-').toLowerCase();
    if (normalized.startsWith('ru')) {
      return normalized.startsWith('ru-ru') ? 'ru-RU' : normalized;
    }
  }
  return 'ru-RU';
}

/// Ignore late "final" recognition callbacks: they must not overwrite text the
/// user typed or an input already cleared after a successful AI request.
bool acceptVoiceResult({
  required bool listening,
  required int session,
  required int currentSession,
}) => listening && session == currentSession;

String friendlyVoiceError(SpeechRecognitionError error) {
  final code = error.errorMsg.toLowerCase();
  if (code.contains('not-allowed') || code.contains('service-not-allowed')) {
    return 'Доступ к микрофону запрещён. Разрешите его в настройках сайта Chrome. '
        '$voiceFallbackHint';
  }
  if (code.contains('network')) {
    return 'Сервис распознавания браузера недоступен без интернета. '
        '$voiceFallbackHint';
  }
  if (code.contains('audio-capture')) {
    return 'Микрофон не найден. Проверьте разрешение или используйте микрофон клавиатуры.';
  }
  if (code.contains('no-speech')) {
    return 'Речь не распознана. Попробуйте ещё раз или введите текст вручную.';
  }
  if (code.contains('not supported') || code.contains('speech_not_supported')) {
    return 'Этот браузер не поддерживает встроенную диктовку. $voiceFallbackHint';
  }
  return 'Не удалось распознать речь. Проверьте микрофон и интернет. '
      '$voiceFallbackHint';
}

/// One-time browser-service notice, not an age or AI consent dialog. The
/// recognized text is treated exactly like typed text; raw audio is never
/// stored by this app or sent to Gemini.
Future<bool> ensureVoiceNotice(
  BuildContext context,
  LocalPreferences store,
) async {
  // A dialog opened before a completed clear must not reinstate its notice.
  final privacyEpoch = LocalPreferences.privacyEpoch;
  bool current() => LocalPreferences.privacyEpochIsCurrent(privacyEpoch);
  if (!current()) return false;
  if (store.getString('_voice_notice_v1') == 'accepted') return true;
  if (!context.mounted) return false;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Диктовка через браузер'),
      content: const SingleChildScrollView(
        child: Text(
          'Аудио обрабатывает сервис распознавания вашего браузера '
          '(в Android Chrome — обычно Google), а не сервер AI приложения. '
          'В AI отправляется только распознанный текст после вашего запроса; '
          'запись в приложении не сохраняется.\n\n'
          'Если вы не хотите передавать аудио сервису браузера, '
          'используйте микрофон клавиатуры или обычный ввод.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Вводить текстом'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Включить диктовку'),
        ),
      ],
    ),
  );
  if (accepted != true || !current()) return false;
  await store.setString(
    '_voice_notice_v1',
    'accepted', // Deliberately not synced: browser capabilities are device-local.
  );
  return current() && store.getString('_voice_notice_v1') == 'accepted';
}
