/// Native and test builds simply show the manual installation instructions.
bool get canInstallWebApp => false;
bool get isWebAppInstalled => false;
Future<String> requestWebAppInstall() async => 'unavailable';
