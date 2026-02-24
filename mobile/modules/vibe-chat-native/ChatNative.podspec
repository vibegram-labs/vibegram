require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ChatNative'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = 'Vibegram'
  s.homepage       = 'https://example.com/chat-native'
  s.platform       = :ios, '16.0'
  s.source         = { :git => 'https://github.com/expo/expo.git' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.dependency 'Giphy'
  # Needed by VibeNativeCallUiCoordinator native video renderer (RTCMTLVideoView / RTCVideoTrack)
  s.dependency 'JitsiWebRTC', '~> 124.0.0'
  s.frameworks = ['CallKit', 'PushKit', 'AVFoundation']

  s.source_files = 'ios/**/*.{swift,h,m,mm}'
  s.resources = ['ios/Resources/**/*']
  s.swift_version = '5.7'
end
