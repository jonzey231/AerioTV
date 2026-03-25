use_frameworks!

target 'Aerio_iOS' do
  platform :ios, '18.0'
  # Video player — LGPL 2.1 — handles MPEG-TS, HLS, RTSP and virtually all IPTV formats
  pod 'MobileVLCKit'

  # pod 'OpenCastSwift', :git => 'https://github.com/mhmiles/OpenCastSwift.git', :branch => 'main'
end

target 'Aerio_tvOS' do
  platform :tvos, '18.0'
  # tvOS variant of VLCKit — same codec support as MobileVLCKit
  pod 'TVVLCKit'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      # Set deployment targets per platform
      if t.platform_name.to_s == 'tvos'
        config.build_settings['TVOS_DEPLOYMENT_TARGET'] = '18.0'
      else
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
      end
    end
  end

  # Fix VLCKit xcframework: prevent it being embedded at the app bundle
  # root (which fails the "must be under Frameworks" App Store validation check)
  # by marking it as do-not-embed — the CocoaPods copy-frameworks script handles
  # placing it in the correct Frameworks/ subdirectory.
  installer.pods_project.targets.each do |t|
    if t.name == 'MobileVLCKit' || t.name == 'TVVLCKit'
      t.build_configurations.each do |config|
        config.build_settings['SKIP_INSTALL'] = 'YES'
        config.build_settings['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'NO'
      end
    end
  end
end
