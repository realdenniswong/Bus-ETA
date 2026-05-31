require 'xcodeproj'
project_path = 'KMB Time.xcodeproj'
project = Xcodeproj::Project.open(project_path)

widget_target = project.targets.find { |t| t.name == 'BusETAWidget' }
if widget_target
  widget_target.build_configurations.each do |config|
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['INFOPLIST_FILE'] = 'BusETAWidget/Info.plist'
  end
end

project.save
