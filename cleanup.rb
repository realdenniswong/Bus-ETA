require 'xcodeproj'
project_path = 'KMB Time.xcodeproj'
project = Xcodeproj::Project.open(project_path)

refs = project.products_group.files.select { |f| f.path == 'BusETAWidget.appex' }
if refs.count > 1
  # Keep the one that is actually used by the target
  widget_target = project.targets.find { |t| t.name == 'BusETAWidget' }
  valid_ref = widget_target.product_reference
  
  refs.each do |ref|
    if ref != valid_ref
      ref.remove_from_project
    end
  end
end

project.save
