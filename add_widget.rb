require 'xcodeproj'
project_path = 'KMB Time.xcodeproj'
project = Xcodeproj::Project.open(project_path)

widget_name = 'BusETAWidget'

if project.targets.any? { |t| t.name == widget_name }
  project.targets.find { |t| t.name == widget_name }.remove_from_project
end

widget_target = project.new_target(:app_extension, widget_name, :ios, '17.0')
product_ref = project.products_group.new_reference("#{widget_name}.appex", :built_products)
product_ref.include_in_index = '0'
product_ref.set_explicit_file_type('wrapper.app-extension')
widget_target.product_reference = product_ref

widget_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'hk.com.karyee.KMB-Time.BusETAWidget'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  config.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'BusETAWidget'
  config.build_settings['INFOPLIST_KEY_NSExtensionPointIdentifier'] = 'com.apple.widgetkit-extension'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
end

group = project.main_group.find_subpath(widget_name, true)
group.set_source_tree('<group>')
group.set_path(widget_name)

['SwiftUI.framework', 'WidgetKit.framework', 'ActivityKit.framework'].each do |fw|
  file_ref = project.frameworks_group.files.find { |f| f.path.include?(fw) } || project.frameworks_group.new_reference("System/Library/Frameworks/#{fw}", :developer_dir)
  widget_target.frameworks_build_phase.add_file_reference(file_ref)
end

app_target = project.targets.find { |t| t.name == 'KMB Time' }
app_target.add_dependency(widget_target)
embed_phase = app_target.build_phases.find { |p| p.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) && p.symbol_dst_subfolder_spec == :plug_ins }
unless embed_phase
  embed_phase = app_target.new_copy_files_build_phase('Embed Foundation Extensions')
  embed_phase.symbol_dst_subfolder_spec = :plug_ins
end
build_file = embed_phase.add_file_reference(widget_target.product_reference)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

file_ref = group.files.find { |f| f.path == 'BusETAWidget.swift' } || group.new_file('BusETAWidget.swift')
widget_target.source_build_phase.add_file_reference(file_ref)

attr_ref = project.main_group.new_reference('KMB Time/BusETAAttributes.swift')
widget_target.source_build_phase.add_file_reference(attr_ref)

project.save
