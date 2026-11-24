import 'dart:typed_data';

/// Native builds have no generic browser download API. Share is the only
/// supported delivery path there; returning false makes the caller report an
/// honest failure instead of claiming that a file was saved.
Future<bool> browserDownloadBackupFile(
  Uint8List bytes,
  String fileName,
  String mimeType,
) async {
  throw UnsupportedError('Браузерная загрузка недоступна в этой сборке');
}
