//
//  NearbyDashboardSectionView.swift
//  KMB Time
//

import SwiftUI
import CoreLocation

struct NearbyDashboardSectionView: View {
    @EnvironmentObject var favoritesManager: FavoritesManager
    
    @ObservedObject var locationManager: LocationManager
    @Binding var expandedStopIds: Set<String>
    @Binding var viewMode: DashboardViewMode
    
    let allStops: [StopInfo]
    let nearbyStops: [NearbyStopModel]
    let currentTime: Date
    
    let onRequestLocation: () -> Void
    let onRouteSelected: (NearbyRouteModel, StopInfo) -> Void
    let onSetTimer: (NearbyRouteModel, StopInfo) -> Void
    let onShowToast: (String) -> Void
    
    // MARK: - Sorting Helpers
    
    private func sortedRoutes(for routes: [NearbyRouteModel]) -> [NearbyRouteModel] {
        return routes.sorted { a, b in
            if a.directionCode != b.directionCode {
                return a.directionCode == "O" // 去程排前面
            }
            return a.route.localizedStandardCompare(b.route) == .orderedAscending
        }
    }
    
    var flatRoutes: [(route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance)] {
        var all: [(route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance)] = []
        
        for stopModel in nearbyStops {
            for route in stopModel.routes {
                all.append((route: route, stop: stopModel.stopInfo, distance: stopModel.distance))
            }
        }
        
        return all.sorted(by: { a, b in
            if a.distance != b.distance {
                return a.distance < b.distance
            }
            return a.route.route.localizedStandardCompare(b.route.route) == .orderedAscending
        })
    }
    
    struct StationNameGroup: Identifiable {
        var id: String { stationName }
        let stationName: String
        var minDistance: CLLocationDistance
        var outbound: [(route: NearbyRouteModel, stopInfo: StopInfo)]
        var inbound: [(route: NearbyRouteModel, stopInfo: StopInfo)]
    }
    
    var groupedByStationName: [StationNameGroup] {
        var dict: [String: StationNameGroup] = [:]
        
        for stopModel in nearbyStops {
            let rawName = stopModel.stopInfo.name_tc
            let cleanName = rawName.replacingOccurrences(
                of: "\\s*\\([^)]+\\)\\s*$",
                with: "",
                options: .regularExpression
            )
            let dist = stopModel.distance
            
            if dict[cleanName] == nil {
                dict[cleanName] = StationNameGroup(stationName: cleanName, minDistance: dist, outbound: [], inbound: [])
            }
            
            dict[cleanName]!.minDistance = min(dict[cleanName]!.minDistance, dist)
            
            for route in stopModel.routes {
                if route.directionCode == "O" {
                    dict[cleanName]!.outbound.append((route: route, stopInfo: stopModel.stopInfo))
                } else {
                    dict[cleanName]!.inbound.append((route: route, stopInfo: stopModel.stopInfo))
                }
            }
        }
        
        var result = Array(dict.values)
        result.sort { $0.minDistance < $1.minDistance }
        
        for i in 0..<result.count {
            result[i].outbound.sort {
                let id1 = extractPoleId(from: $0.stopInfo.name_tc)
                let id2 = extractPoleId(from: $1.stopInfo.name_tc)
                if id1 == id2 {
                    return $0.route.route.localizedStandardCompare($1.route.route) == .orderedAscending
                }
                return id1.localizedStandardCompare(id2) == .orderedAscending
            }
            result[i].inbound.sort {
                let id1 = extractPoleId(from: $0.stopInfo.name_tc)
                let id2 = extractPoleId(from: $1.stopInfo.name_tc)
                if id1 == id2 {
                    return $0.route.route.localizedStandardCompare($1.route.route) == .orderedAscending
                }
                return id1.localizedStandardCompare(id2) == .orderedAscending
            }
        }
        return result
    }
    
    var body: some View {
        let status = locationManager.authorizationStatus
        
        if status == .notDetermined {
            permissionCard(
                icon: "location.circle.fill", color: .blue,
                title: "需要位置權限",
                description: "請允許取用你的位置以顯示附近車站",
                buttonText: "授權",
                action: onRequestLocation
            )
        } else if status == .denied || status == .restricted {
            permissionCard(
                icon: "location.slash.circle.fill", color: .red,
                title: "未開啟位置權限",
                description: "請前往「設定」為應用程式開啟定位權限",
                buttonText: "前往設定",
                action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            )
        } else {
            if locationManager.location == nil || allStops.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(allStops.isEmpty ? "正在載入巴士站..." : "正在尋找附近車站...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 250)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if nearbyStops.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("附近沒有九巴車站")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                if viewMode == .byStation {
                    renderByStation()
                } else if viewMode == .byStationName {
                    renderByStationName()
                } else {
                    renderFlatList()
                }
            }
        }
    }
    
    @ViewBuilder
    private func renderByStation() -> some View {
        ForEach(nearbyStops) { stopModel in
            let isExpanded = expandedStopIds.contains(stopModel.stopInfo.stop)
            
            Section {
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        toggleStopExpanded(stopModel.stopInfo.stop)
                    }
                }) {
                    HStack(alignment: .center) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundColor(.red)
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stopModel.stopInfo.name_tc)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 12) {
                            Text(formatDistance(stopModel.distance))
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(6)
                            
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                if isExpanded {
                    if stopModel.routes.isEmpty {
                        Text("暫無服務...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(sortedRoutes(for: stopModel.routes)) { route in
                            routeRow(route: route, stopInfo: stopModel.stopInfo)
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func renderFlatList() -> some View {
        Section {
            // 🌟 1. 進行去重邏輯：只保留每一條路線 (包含方向) 距離最近嗰一個車站
            let uniqueRoutes = flatRoutes.reduce(into: [String: (route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance)]()) { dict, item in
                let key = "\(item.route.route)-\(item.route.directionCode)"
                
                // 如果 Key 未存在，或者新嘅距離比舊嘅短，就更新佢
                if let existing = dict[key] {
                    if item.distance < existing.distance {
                        dict[key] = item
                    }
                } else {
                    dict[key] = item
                }
            }
            
            // 🌟 2. 將 Dict 轉返做陣列並按距離排序
            let filteredRoutes = Array(uniqueRoutes.values).sorted { $0.distance < $1.distance }
            
            if filteredRoutes.isEmpty {
                Text("暫無服務...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(filteredRoutes, id: \.route.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "mappin.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                            Text("\(item.stop.name_tc) (\(formatDistance(item.distance)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 2)
                        
                        // 🌟 呢度繼續用你想要顯示距離嘅 Detailed Row
                        routeRowWithDetails(route: item.route, stopInfo: item.stop)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    @ViewBuilder
    private func renderByStationName() -> some View {
        ForEach(groupedByStationName) { group in
            let isExpanded = expandedStopIds.contains(group.stationName)
            
            Section {
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        toggleStopExpanded(group.stationName)
                    }
                }) {
                    HStack(alignment: .center) {
                        Image(systemName: "building.2.crop.circle")
                            .foregroundColor(.red)
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.stationName)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 12) {
                            Text(formatDistance(group.minDistance))
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(6)
                            
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                if isExpanded {
                    if group.outbound.isEmpty && group.inbound.isEmpty {
                        Text("暫無服務...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(group.outbound, id: \.route.id) { item in
                            routeRowWithStationNumber(route: item.route, stopInfo: item.stopInfo)
                        }
                        ForEach(group.inbound, id: \.route.id) { item in
                            routeRowWithStationNumber(route: item.route, stopInfo: item.stopInfo)
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func routeRowWithStationNumber(route: NearbyRouteModel, stopInfo: StopInfo) -> some View {
        Button(action: { onRouteSelected(route, stopInfo) }) {
            HStack(alignment: .center, spacing: 12) {
                // Company Tag Block
                VStack(spacing: 2) {
                    Text(route.route)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 32)
                        .background(route.route.contains("E") || route.route.contains("A") ? Color.orange : Color(red: 0.65, green: 0.08, blue: 0.12))
                        .cornerRadius(8)
                    Text(route.route.contains("E") || route.route.contains("A") ? "城巴" : "九巴")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(route.route.contains("E") || route.route.contains("A") ? .orange : Color(red: 0.65, green: 0.08, blue: 0.12))
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("往")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(route.destNameTc)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                    }
                }
                
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // 1. Used in renderByStation() -> NO Distance/Name Info
    @ViewBuilder
    private func routeRow(route: NearbyRouteModel, stopInfo: StopInfo) -> some View {
        Button(action: { onRouteSelected(route, stopInfo) }) {
            HStack(alignment: .center, spacing: 12) {
                companyTagView(route: route)
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("往")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(route.destNameTc)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func routeRowWithDetails(route: NearbyRouteModel, stopInfo: StopInfo) -> some View {
        Button(action: { onRouteSelected(route, stopInfo) }) {
            HStack(alignment: .center, spacing: 12) {
                companyTagView(route: route)
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("往")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(route.destNameTc)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    
                    // 🌟 This info ONLY appears in the flat list
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill").font(.caption2).foregroundColor(.secondary)
                        Text("\(stopInfo.name_tc) • \(formatDistance(self.nearbyStops.first(where: { $0.stopInfo.stop == stopInfo.stop })?.distance ?? 0))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // Helper to keep code clean
    @ViewBuilder
    private func companyTagView(route: NearbyRouteModel) -> some View {
        // 🌟 完全基於模型數據，唔再做 String parsing
        let isCTB = (route.co == "CTB")
        
        VStack(spacing: 2) {
            Text(route.route)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 52, height: 32)
                // 橙色畀城巴，紅色畀九巴
                .background(isCTB ? Color.orange : Color(red: 0.65, green: 0.08, blue: 0.12))
                .cornerRadius(8)
        }
    }
    
    
    
    // MARK: - Local Helpers
    
    private func toggleStopExpanded(_ stopId: String) {
        if expandedStopIds.contains(stopId) {
            expandedStopIds.remove(stopId)
        } else {
            expandedStopIds.insert(stopId)
        }
    }
    
    private func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return String(format: "%.0f 米", distance)
        } else {
            return String(format: "%.1f 公里", distance / 1000)
        }
    }
    
    @ViewBuilder
    private func permissionCard(icon: String, color: Color, title: String, description: String, buttonText: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 60, height: 60)
                .foregroundColor(color)
                .padding(.top, 10)
            
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            
            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            
            Button(action: action) {
                Text(buttonText)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(color == .blue ? AnyView(LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .leading, endPoint: .trailing)) : AnyView(color))
                    .cornerRadius(12)
                    .shadow(color: color.opacity(0.3), radius: 6, x: 0, y: 3)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
    
    private func extractPoleId(from rawName: String) -> String {
        if let lastOpen = rawName.lastIndex(of: "("),
           let lastClose = rawName.lastIndex(of: ")"),
           lastOpen < lastClose {
            
            let idString = rawName[rawName.index(after: lastOpen)..<lastClose]
            return String(idString)
        }
        return "N/A"
    }
    
    // Add this helper inside NearbyDashboardSectionView
    private func getCompany(for route: NearbyRouteModel) -> String {
        // Since this is the Dashboard, and you are pulling from local data,
        // you can verify the operator by the direction/route pattern.
        // If your CSV data is Citybus, return "CTB", otherwise "KMB".
        // Or, if you added a 'co' property to NearbyRouteModel, use that!
        return route.route.contains("E") || route.route.contains("A") ? "CTB" : "KMB"
        // ^ Note: Replace this logic with your actual source check if available.
    }
}
