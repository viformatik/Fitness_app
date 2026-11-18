// Public barrel retains compatibility with the previous single-file tests.
export 'legacy.dart';
import 'legacy.dart' as legacy;

Future<void> main() => legacy.main();
