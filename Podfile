platform :ios, '18.0'
use_frameworks!

target 'Dispatcharr_iOS' do
  # Video player — LGPL 2.1 — handles MPEG-TS, HLS, RTSP and virtually all IPTV formats
  pod 'MobileVLCKit'

  # Google Cast (open-source implementation — no proprietary Google SDK required)
  # OpenCastSwift implements the Cast v2 protocol natively in Swift.
  # Uncomment when ready to enable Cast support:
  # pod 'OpenCastSwift', :git => 'https://github.com/mhmiles/OpenCastSwift.git', :branch => 'main'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
    end
  end
end
