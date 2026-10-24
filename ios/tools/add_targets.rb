#!/usr/bin/env ruby
# Adds the Xcode targets that `flutter create` does not generate (iOS plan §3), and checks
# the Runner settings the App Store upload depends on.
#
# The committed Runner.xcodeproj is exactly what `flutter create --platforms=ios` wrote, plus
# the edits I0 made (bundle id, iOS 17.0, iPhone only, PrivacyInfo.xcprivacy). Extra targets
# (Phase 2 Live Activity extension, Phase 3 Watch app) are added here instead of by hand, so
# Flutter's xcconfig includes, its xcode_backend.sh build phases and the Debug/Profile/Release
# configs stay untouched. CocoaPods is built on the same xcodeproj gem.
#
# CI runs it on macOS before `pod install`. It is idempotent: a target that already exists is
# left alone, and the project is only saved when something was added.
#
#     ruby ios/tools/add_targets.rb           # check Runner, add missing targets
#     ruby ios/tools/add_targets.rb --check   # check only, never writes
#
# Not verified: no Ruby on the dev host. EXTRA_TARGETS is empty until Phase 2, so add_target
# has not run yet; its first user proves it on CI.
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Runner.xcodeproj', __dir__)
BUNDLE_ID = 'app.runsupreme'
DEPLOYMENT_TARGET = '17.0'

# One entry per extra target. Phase 2 adds, for example:
#   { name: 'RunLiveActivity', type: :app_extension, bundle_id: "#{BUNDLE_ID}.RunLiveActivity",
#     sources: 'RunLiveActivity', info_plist: 'RunLiveActivity/Info.plist', embed: true }
# Shared sources (a LiveActivityIntent needs membership in both app and extension) go in
# `shared_with_runner: ['RunLiveActivity/LapIntent.swift']`.
EXTRA_TARGETS = [].freeze

def fail!(msg)
  warn "add_targets: #{msg}"
  exit 1
end

def check_runner(project)
  runner = project.targets.find { |t| t.name == 'Runner' } or fail!('no Runner target')
  runner.build_configurations.each do |config|
    s = config.build_settings
    fail!("#{config.name}: bundle id #{s['PRODUCT_BUNDLE_IDENTIFIER']}") unless s['PRODUCT_BUNDLE_IDENTIFIER'] == BUNDLE_ID
  end
  project.build_configurations.each do |config|
    s = config.build_settings
    fail!("#{config.name}: deployment target #{s['IPHONEOS_DEPLOYMENT_TARGET']}") unless s['IPHONEOS_DEPLOYMENT_TARGET'] == DEPLOYMENT_TARGET
    fail!("#{config.name}: device family #{s['TARGETED_DEVICE_FAMILY']}") unless s['TARGETED_DEVICE_FAMILY'].to_s == '1'
  end
  resources = runner.resources_build_phase.files_references.compact.map(&:path)
  fail!('PrivacyInfo.xcprivacy is not a Runner resource') unless resources.include?('PrivacyInfo.xcprivacy')
  runner
end

def add_target(project, runner, spec)
  target = project.new_target(spec[:type], spec[:name], :ios, DEPLOYMENT_TARGET)
  group = project.main_group.find_subpath(spec[:sources], true)
  group.set_source_tree('<group>')
  group.set_path(spec[:sources])
  sources_dir = File.join(File.dirname(PROJECT_PATH), spec[:sources])
  Dir.glob(File.join(sources_dir, '**', '*.swift')).sort.each do |file|
    ref = group.new_reference(file)
    target.add_file_references([ref])
  end
  target.build_configurations.each do |config|
    s = config.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER'] = spec[:bundle_id]
    s['INFOPLIST_FILE'] = spec[:info_plist] if spec[:info_plist]
    s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
    s['TARGETED_DEVICE_FAMILY'] = '1'
    s['SWIFT_VERSION'] = '5.0'
    # Same CFBundleVersion as the app (App Store rule): Flutter sets it from pubspec / --build-number.
    s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
    s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
  end
  Array(spec[:shared_with_runner]).each do |path|
    ref = group.files.find { |f| f.real_path.to_s.end_with?(path) } or fail!("#{path} not found")
    runner.add_file_references([ref])
  end
  if spec[:embed]
    runner.add_dependency(target)
    phase = runner.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' } ||
            runner.new_copy_files_build_phase('Embed Foundation Extensions').tap { |p| p.symbol_dst_subfolder_spec = :plug_ins }
    phase.add_file_reference(target.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  end
  target
end

# K3: the shared Kotlin recorder core. `RunCore.xcframework` is built by CI (Gradle task
# assembleRunCoreReleaseXCFramework in android/core-jvm) and copied to ios/RunCore/; it is linked into
# Runner only (a static framework, so no embed phase). The Swift wrapper lives in Runner/RunCore
# and its XCTest in RunnerTests (hosted in Runner, so it reaches the core through the app).
CORE_XCFRAMEWORK = 'RunCore/RunCore.xcframework'
# P3 adds the recorder host, its Pigeon API, and the diagnostics log next to the facade; P4 the cue player.
CORE_RUNNER_SOURCES = ['CoreFacade.swift', 'RecorderHost.swift', 'RecorderApiHost.swift', 'Diagnostics.swift', 'CuePlayer.swift'].freeze
CORE_TEST_SOURCES = ['CoreFacadeTests.swift', 'RecorderHostTests.swift', 'CuePlayerTests.swift'].freeze

def add_sources(project, target, group_name, files, subdir: nil)
  group = project.main_group.find_subpath(group_name, false) or fail!("no #{group_name} group")
  group = (group.children.find { |c| c.display_name == subdir } || group.new_group(subdir, subdir)) if subdir
  added = false
  files.each do |name|
    next if group.files.any? { |f| f.path == name }
    target.add_file_references([group.new_reference(name)])
    added = true
  end
  added
end

# Returns true when the project changed.
def wire_core(project, runner)
  tests = project.targets.find { |t| t.name == 'RunnerTests' } or fail!('no RunnerTests target')
  fw = File.join(File.dirname(PROJECT_PATH), CORE_XCFRAMEWORK)
  fail!("#{CORE_XCFRAMEWORK} missing: build it first (cd android/core-jvm && ./gradlew assembleRunCoreReleaseXCFramework, copy build/XCFrameworks/release/RunCore.xcframework to ios/RunCore/)") unless File.directory?(fw)
  changed = false
  # The framework has no x86_64 simulator slice (Kotlin/Native iosX64 is not built), and Flutter
  # builds the simulator app for x86_64 + arm64 unless told otherwise.
  [runner, tests].each do |t|
    t.build_configurations.each do |config|
      key = 'EXCLUDED_ARCHS[sdk=iphonesimulator*]'
      next if config.build_settings[key] == 'x86_64'
      config.build_settings[key] = 'x86_64'
      changed = true
    end
  end
  unless project.frameworks_group.files.any? { |f| f.path == CORE_XCFRAMEWORK }
    ref = project.frameworks_group.new_reference(CORE_XCFRAMEWORK, :project)
    ref.last_known_file_type = 'wrapper.xcframework'
    runner.frameworks_build_phase.add_file_reference(ref, true)
    changed = true
  end
  changed |= add_sources(project, runner, 'Runner', CORE_RUNNER_SOURCES, subdir: 'RunCore')
  changed |= add_sources(project, tests, 'RunnerTests', CORE_TEST_SOURCES)
  changed
end

check_only = ARGV.include?('--check')
project = Xcodeproj::Project.open(PROJECT_PATH)
runner = check_runner(project)
missing = EXTRA_TARGETS.reject { |spec| project.targets.any? { |t| t.name == spec[:name] } }
if check_only
  fail!("missing targets: #{missing.map { |s| s[:name] }.join(', ')}") unless missing.empty?
  puts "add_targets: Runner ok, #{EXTRA_TARGETS.size} extra target(s) present"
  exit 0
end
missing.each do |spec|
  add_target(project, runner, spec)
  puts "add_targets: added #{spec[:name]}"
end
core_changed = wire_core(project, runner)
project.save if core_changed || !missing.empty?
puts "add_targets: Runner ok, #{missing.size} target(s) added, #{EXTRA_TARGETS.size - missing.size} already present, core #{core_changed ? 'wired' : 'already wired'}"
