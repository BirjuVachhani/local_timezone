# test_host

Not an example. This is the application the device tests get installed into.

`flutter test -d <device>` has to build and install an app, so it needs a
runner project: `android/app` for Android, `ios/Runner` for iOS. A package has
neither, and cannot be given them, so the tests in
[`../integration_test`](../integration_test) have nowhere to run without an app
somewhere in the tree.

The app does not have to own those tests. Flutter does require the entrypoint
to be below this project's `integration_test/` directory before it selects the
device test backend, so that directory contains one delegating file and no test
cases of its own:

```sh
cd packages/flutter_local_timezone/test_host
flutter test integration_test -d <device>
```

Use that path, not `../integration_test`. `flutter test` classifies a file as a
device test only when its path starts with `<cwd>/integration_test`, and a path
that fails the check does not error. It quietly falls back to `flutter_tester`
on the host, ignoring `-d`, building no app, and never loading the platform
code the suite exists to cover. The run goes green having tested the host
instead of the device.

Nothing in `lib/` is under test. The package requires no permissions, no
plugins and no native code, so this is the stock `flutter create --empty`
output with the generated pubspec replaced, plus that test delegate.

Every run prints `Warning: integration_test plugin was not detected`. It is
noise. That warning is for people driving the tests through `flutter drive` or
native instrumentation, where results come back over the plugin's method
channel; `flutter test -d` reports over the VM service instead. Verified rather
than assumed: a deliberately failing case still fails the run and still exits
1.

Excluded from the published archive by `../.pubignore`.
