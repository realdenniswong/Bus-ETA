require 'xcodeproj'
project_path = 'KMB Time.xcodeproj'
project = Xcodeproj::Project.open(project_path)

refs = project.files.select { |f| f.path && f.path.include?('BusETAAttributes.swift') }
refs.each do |ref|
  ref.remove_from_project
end

project.save
