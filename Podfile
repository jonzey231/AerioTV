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
  # generated Pods project. The prompt is gated by the project's
  # LastUpgradeCheck lagging the current Xcode; CocoaPods regenerates the
  # project each `pod install` with an older marker, so the nag returns after
  # every install. Stamping the current Xcode version suppresses it without
  # touching any build behaviour (it is only a validation marker). We do NOT
  # blanket-apply the individual recommended settings -- enabling the Clang
  # Module Verifier on the vendored Protobuf / Cast pods can surface fresh
  # errors, which we don't want to risk right before a release.
  installer.pods_project.root_object.attributes['LastUpgradeCheck'] = 2700
  installer.pods_project.root_object.attributes['LastSwiftUpdateCheck'] = 2700

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
    end
  end
end
