Pod::Spec.new do |s|
  s.name             = 'LemuAnalytics'
  s.version          = '1.1.0'
  s.summary          = 'Lemu tracking SDK for iOS and tvOS: events, purchases, screens and app lifecycle.'
  s.description      = <<~DESC
    Sends events from iOS and tvOS apps to Lemu (https://lemuai.com): Meta standard
    event names, a typed purchase() call, identify, app lifecycle events, deep link
    attribution and screen views. Offline queue, retries, consent and opt-out.
    No advertising identifiers.
  DESC
  s.homepage         = 'https://github.com/LemuAI/lemu-sdks/tree/main/ios'
  s.license          = { :type => 'MIT', :file => 'ios/LICENSE' }
  s.author           = 'LemuAI'
  s.source           = { :git => 'https://github.com/LemuAI/lemu-sdks.git', :tag => "ios-v#{s.version}" }

  s.ios.deployment_target  = '13.0'
  s.tvos.deployment_target = '13.0'
  # Swift 5 language mode, the same as the Swift package (tools version 5.7).
  s.swift_versions = ['5.7', '5.8', '5.9', '5.10']

  s.source_files = 'ios/Sources/LemuAnalytics/**/*.swift'
  s.resource_bundles = {
    'LemuAnalyticsPrivacy' => ['ios/Sources/LemuAnalytics/PrivacyInfo.xcprivacy']
  }
  s.frameworks = 'Foundation'
  s.ios.frameworks = 'UIKit'
  s.tvos.frameworks = 'UIKit'
end
