// Flutter only selects its device integration-test backend for files below the
// runner project's own `integration_test` directory. Keep the test cases in
// the package that owns them, and expose this delegating device entrypoint.
import '../../integration_test/device_test.dart' as device_test;

void main() => device_test.main();
