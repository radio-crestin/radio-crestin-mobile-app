Pod::Spec.new do |s|
  s.name             = 'flutter_airplay'
  s.version          = '1.0.0'
  s.summary          = 'iOS AirPlay audio route picker for Flutter.'
  s.description      = 'Wraps AVRoutePickerView to show available AirPlay, Bluetooth, and speaker devices.'
  s.homepage         = 'https://github.com/niclas-niclas/radio-crestin-mobile-app'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Radio Crestin' => 'contact@radiocrestin.ro' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
