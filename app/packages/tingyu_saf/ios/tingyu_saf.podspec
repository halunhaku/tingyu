#
# 听屿的系统授权目录桥（iOS 侧）。Android 侧在 ../android/。
#
Pod::Spec.new do |s|
  s.name             = 'tingyu_saf'
  s.version          = '0.0.1'
  s.summary          = '听屿的系统授权目录桥：Android SAF tree URI 与 iOS 安全作用域书签。'
  s.description      = <<-DESC
听屿「本地音乐目录」的系统授权桥。iOS 侧走文档选择器 + 安全作用域书签：
用户显式授权一个目录，插件把授权保存为可持久化的书签，并在进程内保持安全作用域访问。
                       DESC
  s.homepage         = 'https://github.com/halunhaku/tingyu'
  s.license          = { :type => 'Proprietary', :text => 'Copyright (c) halunhaku' }
  s.author           = { 'halunhaku' => 'halunhaku@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.platform         = :ios, '15.0'
  s.dependency 'Flutter'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
