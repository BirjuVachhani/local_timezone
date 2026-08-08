#
# One podspec for both Apple platforms, for projects that use CocoaPods rather
# than Swift Package Manager. The two paths coexist: the tool picks whichever
# the host project is set up for, so both have to keep working.
#
# Run `pod lib lint flutter_local_timezone.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_local_timezone'
  s.version          = '0.1.0'
  s.summary          = 'Notifies when the device local timezone changes.'
  s.description      = <<-DESC
Reports iOS and macOS system timezone changes to Dart, so
flutter_local_timezone can re-resolve the zone and notify its listeners.
                       DESC
  s.homepage         = 'https://github.com/BirjuVachhani/local_timezone'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Birju Vachhani' => 'birju.vachhani@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'flutter_local_timezone/Sources/flutter_local_timezone/**/*.swift'

  # Per platform rather than a single `s.platform`, which is what makes one
  # podspec able to serve both. The framework names differ and the deployment
  # targets differ, and nothing else does.
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
