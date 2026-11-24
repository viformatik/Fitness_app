import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_delivery_web.dart' if (dart.library.io) 'backup_delivery_stub.dart';

/// How a generated backup left the application. A share sheet's successful
/// return does not prove that an operating system received or saved a file.
enum BackupDelivery { shared, downloaded, failed }

typedef BackupSharer = Future<void> Function(
  Uint8List bytes,
  String fileName,
  String mimeType,
  Rect? sharePositionOrigin,
);

typedef BackupDownloader = Future<bool> Function(
  Uint8List bytes,
  String fileName,
  String mimeType,
);

Future<void> _platformShare(
  Uint8List bytes,
  String fileName,
  String mimeType,
  Rect? sharePositionOrigin,
) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(bytes, mimeType: mimeType),
      ],
      fileNameOverrides: [fileName],
      sharePositionOrigin: sharePositionOrigin,
      // Let our own, observable browser fallback handle a missing canShare.
      // Otherwise the plugin silently downloads a second time and the UI
      // cannot tell the user what actually happened.
      downloadFallbackEnabled: false,
    ),
  );
}

/// Try the system share first and fall back to a real browser download on any
/// failure. Never reports success when neither path worked.
Future<BackupDelivery> deliverBackupFile(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
  Rect? sharePositionOrigin,
  BackupSharer? share,
  BackupDownloader? download,
}) async {
  try {
    await (share ?? _platformShare)(bytes, fileName, mimeType, sharePositionOrigin);
    return BackupDelivery.shared;
  } catch (_) {
    // A missing navigator.canShare, a cancelled plugin channel or any other
    // share failure is not fatal: the user still needs a way to save the file.
  }
  try {
    final fallback = download ?? browserDownloadBackupFile;
    final ok = await fallback(bytes, fileName, mimeType);
    if (ok) return BackupDelivery.downloaded;
  } catch (_) {
    // Report failure below; never invent a successful delivery.
  }
  return BackupDelivery.failed;
}
