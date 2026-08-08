# test_host

Not an example. This is the application the device tests get installed into.

`flutter test -d <device>` has to build and install an app, so it needs a
runner project: `android/app` for Android, `ios/Runner` for iOS. A package has
neither, and cannot be given them, so the tests in
[`../integration_test`](../integration_test) have nowhere to run without an app
somewhere in the tree.

The app does not have to own those tests, which is why they are not in here:

```sh
cd packages/flutter_local_timezone/test_host
flutter test ../integration_test -d <device>
```

Nothing in `lib/` is under test and nothing here needs editing. The package
requires no permissions, no plugins and no native code, so this is the stock
`flutter create --empty` output with the generated pubspec replaced.

Every run prints `Warning: integration_test plugin was not detected`. It is
noise. That warning is for people driving the tests through `flutter drive` or
native instrumentation, where results come back over the plugin's method
channel; `flutter test -d` reports over the VM service instead. Verified rather
than assumed: a deliberately failing case still fails the run and still exits
1.

Excluded from the published archive by `../.pubignore`.
