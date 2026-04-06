use_frameworks!

target 'Aerio_iOS' do
  platform :ios, '18.0'
end

target 'Aerio_tvOS' do
  platform :tvos, '18.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      if t.platform_name.to_s == 'tvos'
        config.build_settings['TVOS_DEPLOYMENT_TARGET'] = '18.0'
      else
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
      end
    end
  end
end
