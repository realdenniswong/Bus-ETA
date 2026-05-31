require 'xcodeproj'
project_path = 'KMB Time.xcodeproj'
project = Xcodeproj::Project.open(project_path)

group = project.main_group.find_subpath('SharedModels', true)
group.set_source_tree('<group>')
group.set_path('SharedModels')

file_ref = group.new_reference('BusETAAttributes.swift')

app_target = project.targets.find { |t| t.name == 'KMB Time' }
widget_target = project.targets.find { |t| t.name == 'BusETAWidget' }

app_target.source_build_phase.add_file_reference(file_ref)
widget_target.source_build_phase.add_file_reference(file_ref)

project.save
