Pod::Spec.new do |s|
  s.name             = 'scan_engine_flutter'
  s.version          = '0.1.0'
  s.summary          = 'iOS support for the DataMuncher scan engine.'
  s.description      = 'Photos library listing, thumbnails and storage totals for the DataMuncher scan engine.'
  s.homepage         = 'https://github.com/dreece44/Data-Muncher'
  s.license          = { :type => 'Proprietary', :text => 'DataMuncher team project' }
  s.author           = { 'DataMuncher team' => 'https://github.com/dreece44/Data-Muncher' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.frameworks       = 'Photos'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
