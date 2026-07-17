use_frameworks!

target 'Aerio_iOS' do
  platform :ios, '18.0'
  # Google Cast iOS sender (GH #33). iOS-only: casts to the same Android TV
  # receiver app id (CFFD302F) that the Android sender uses. The -no-bluetooth
  # variant drops Cast guest mode so no NSBluetoothAlwaysUsageDescription prompt
  # is needed, matching AerioTV's minimal-permission posture.
  pod 'google-cast-sdk-no-bluetooth'
end

target 'Aerio_tvOS' do
  platform :tvos, '18.0'
end

post_install do |installer|
  # Silence Xcode's recurring "Update to recommended settings" prompt on the
  # generated Pods project. CocoaPods regenerates Pods.xcodeproj on every
  # `pod install` with an older upgrade marker AND without the modern
  # recommended settings, so the prompt returns each install. The marker
  # alone is NOT enough -- Xcode 27 also diffs concrete build settings, so we
  # apply the exact recommended set it asks for. All of these are Apple's own
  # recommendations for pod targets; the release build is re-verified green
  # after applying them.
  proj = installer.pods_project
  proj.root_object.attributes['LastUpgradeCheck'] = 2700
  proj.root_object.attributes['LastSwiftUpdateCheck'] = 2700
  # Project-level recommendations: dead-code stripping, default symbol
  # stripping, String Catalog symbol generation, parallel target builds.
  proj.build_configurations.each do |config|
    config.build_settings['DEAD_CODE_STRIPPING'] = 'YES'
    config.build_settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
    # "Reset symbol stripping to defaults" -> drop the overrides CocoaPods sets.
    %w[STRIP_INSTALLED_PRODUCT STRIP_STYLE STRIP_SWIFT_SYMBOLS].each do |k|
      config.build_settings.delete(k)
    end
  end
  proj.root_object.attributes['BuildIndependentTargetsInParallel'] = 'YES'

  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      if t.platform_name.to_s == 'tvos'
        config.build_settings['TVOS_DEPLOYMENT_TARGET'] = '18.0'
      else
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
      end
      # GH #33: google-cast-sdk pulls in the Protobuf pod, whose framework
      # headers use double-quoted includes (e.g. #include "GPBDescriptor.h").
      # Under Xcode 27 this trips -Werror=quoted-include-in-framework-header,
      # producing 186 build errors, ALL inside Pods/Protobuf/objectivec/*.h --
      # none in our code. They are Google's vendored headers, so silence the
      # warning on the pod targets rather than patching upstream sources.
      config.build_settings['CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER'] = 'NO'
      # Per-target recommendations: don't embed the Swift standard libraries in
      # pod frameworks and don't code-sign them at build time (the app re-signs
      # on embed).
      config.build_settings['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'NO'
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      # Enable the Clang module verifier (an Xcode-recommended setting) but tell
      # its stricter modules pass not to treat the Protobuf pod's quoted
      # framework includes (#include "GPBDescriptor.h") as fatal -- without the
      # flag the verifier fails with 186 errors in Google's vendored headers
      # (verified 2026-07-17). CLANG_WARN_...=NO above only covers the normal
      # compile; the verifier needs its own flag.
      config.build_settings['ENABLE_MODULE_VERIFIER'] = 'YES'
      config.build_settings['MODULE_VERIFIER_SUPPORTED_LANGUAGES'] = 'objective-c objective-c++'
      config.build_settings['MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS'] = 'gnu11 gnu++20'
      config.build_settings['OTHER_MODULE_VERIFIER_FLAGS'] = '-Wno-quoted-include-in-framework-header'
    end
  end
end
