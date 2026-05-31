require 'xcodeproj'
project_path = 'KMB Time.xcodeproj'
project = Xcodeproj::Project.open(project_path)

file_path = 'KMB Time/BusETAAttributes.swift'
group = project.main_group.find_subpath('KMB Time', false)
file_ref = group.new_reference(file_path)

app_target = project.targets.find { |t| t.name == 'KMB Time' }
widget_target = project.targets.find { |t| t.name == 'BusETAWidgetExtension' }

app_target.add_file_references([file_ref])
widget_target.add_file_references([file_ref])

project.save
