require 'xcodeproj'
project_path = 'KMB Time.xcodeproj'
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'KMB Time' }
source_phase = app_target.source_build_phase

# Check if BusETAAttributes.swift is in the source build phase
unless source_phase.files.any? { |f| f.file_ref && f.file_ref.path && f.file_ref.path.include?('BusETAAttributes.swift') }
  # Find or create file reference
  group = project.main_group.find_subpath('KMB Time', false)
  file_ref = group.files.find { |f| f.path == 'BusETAAttributes.swift' }
  if file_ref.nil?
    file_ref = group.new_reference('BusETAAttributes.swift')
  end
  source_phase.add_file_reference(file_ref)
end

project.save
