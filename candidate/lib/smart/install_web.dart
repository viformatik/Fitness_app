import 'dart:js_interop';

@JS('fitnessInstall.canInstall')
external JSBoolean _canInstall();

@JS('fitnessInstall.isInstalled')
external JSBoolean _isInstalled();

@JS('fitnessInstall.requestInstall')
external JSPromise<JSString> _requestInstall();

bool get canInstallWebApp {
  try {
    return _canInstall().toDart;
  } catch (_) {
    return false;
  }
}

bool get isWebAppInstalled {
  try {
    return _isInstalled().toDart;
  } catch (_) {
    return false;
  }
}

Future<String> requestWebAppInstall() async {
  try {
    return (await _requestInstall().toDart).toDart;
  } catch (_) {
    return 'unavailable';
  }
}
