require 'xcodeproj'

project_path = 'KMB Time.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Check if target already exists
if project.targets.any? { |t| t.name == 'KMBTimeWidgetExtension' }
  puts "Target already exists."
  exit 0
end

# Create the new target for the Widget Extension
target = project.new_target(:app_extension, 'KMBTimeWidgetExtension', :ios, '17.0')

# Create a group for the extension files
group = project.main_group.new_group('KMBTimeWidgetExtension', 'KMBTimeWidgetExtension')

# Create the Info.plist file reference
# (For modern iOS, Widget extensions usually don't need a plist if using build settings, but we will create a basic one)
# Actually, for Widget Extension, it's easier to set INFOPLIST_FILE to empty or create one.
# Xcode 14+ uses Generate Info.plist file. Let's just set the build settings.

target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.denniswong.KMBTime.KMBTimeWidgetExtension'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
end

# Link SwiftUI and WidgetKit
target.add_frameworks_build_phase
frameworks = ['SwiftUI.framework', 'WidgetKit.framework', 'ActivityKit.framework']
frameworks.each do |fw|
  file_ref = project.frameworks_group.files.find { |f| f.path.include?(fw) } || project.frameworks_group.new_reference("System/Library/Frameworks/#{fw}", :developer_dir)
  target.frameworks_build_phases.add_file_reference(file_ref)
end

# Add source build phase
# We will create LiveActivity.swift
file_ref = group.new_file('LiveActivity.swift')
target.add_file_references([file_ref])

# Add the app extension as a dependency to the main app target
app_target = project.targets.find { |t| t.name == 'KMB Time' }
if app_target
  app_target.add_dependency(target)
  
  # Embed App Extensions phase
  embed_phase = app_target.build_phases.find { |p| p.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) && p.symbol_dst_subfolder_spec == :plug_ins }
  unless embed_phase
    embed_phase = app_target.new_copy_files_build_phase('Embed Foundation Extensions')
    embed_phase.symbol_dst_subfolder_spec = :plug_ins
  end
  
  build_file = embed_phase.add_file_reference(target.product_reference)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

project.save
puts "Successfully added KMBTimeWidgetExtension target."
