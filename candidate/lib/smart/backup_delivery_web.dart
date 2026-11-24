import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Real browser download fallback. The link is never added to the visible UI;
/// it is clicked in response to the user's export action and removed at once.
/// The object URL is revoked after a delay so a slow download can still start.
Future<bool> browserDownloadBackupFile(
  Uint8List bytes,
  String fileName,
  String mimeType,
) async {
  final parts = <web.BlobPart>[bytes.toJS];
  final blob = web.Blob(parts.toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.appendChild(anchor);
  try {
    anchor.click();
  } finally {
    anchor.remove();
  }
  Timer(const Duration(seconds: 30), () {
    web.URL.revokeObjectURL(url);
  });
  return true;
}
