//
//  NearbyDashboardSectionView.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/4/26.
//

import SwiftUI
import CoreLocation

struct NearbyDashboardSectionView: View {
    @ObservedObject var locationManager: LocationManager
    @Binding var expandedStopIds: Set<String>
    @Binding var viewMode: DashboardViewMode
    
    let allStops: [StopInfo]
    let nearbyStops: [NearbyStopModel]
    let currentTime: Date
    
    let onRequestLocation: () -> Void
    let onRouteSelected: (NearbyRouteModel, StopInfo) -> Void
    let onSetTimer: (NearbyRouteModel, StopInfo) -> Void
    
    // Helper to generate a flat list of all routes sorted by distance, then by ETA
    var flatRoutes: [(route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance)] {
        var all: [(route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance)] = []
        
        for stopModel in nearbyStops {
            for route in stopModel.routes {
                all.append((route: route, stop: stopModel.stopInfo, distance: stopModel.distance))
            }
        }
        
        return all.sorted(by: { a, b in
            // 1. 先按距離排序 (由近到遠)
            if a.distance != b.distance {
                return a.distance < b.distance
            }
            // 2. 如果距離一樣 (同一個站)，按最快到站時間 (ETA) 排序
            let aEta = a.route.etas.first?.etaDate ?? Date.distantFuture
            let bEta = b.route.etas.first?.etaDate ?? Date.distantFuture
            return aEta < bEta
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
            
            // This Regex matches a space (optional), followed by an opening parenthesis,
            // any characters that are NOT a closing parenthesis, and a final closing parenthesis
            // at the very end of the string.
            let cleanName = rawName.replacingOccurrences(
                of: "\\s*\\([^)]+\\)\\s*$",
                with: "",
                options: .regularExpression
            )
            
            let dist = stopModel.distance
            
            // Use `cleanName` for grouping instead of `rawName`
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
        
        // Convert to Array and Sort by distance
        var result = Array(dict.values)
        result.sort { $0.minDistance < $1.minDistance }
        
        // NEW SORTING LOGIC: Sort by Station ID first, then by Route Name
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
        // --- HEADER ---
        HStack {
            Text("附近巴士站")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, -10)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        
        // --- CONTENT ---
        let status = locationManager.authorizationStatus
        
        if status == .notDetermined {
            permissionCard(
                icon: "location.circle.fill", color: .blue,
                title: "尋找附近巴士站及抵達時間",
                description: "啟用定位權限，系統會自動探索您目前位置附近的巴士站與即時路線資訊。",
                buttonText: "分享目前位置",
                action: onRequestLocation
            )
        } else if status == .denied || status == .restricted {
            permissionCard(
                icon: "location.slash.circle.fill", color: .red,
                title: "定位權限已關閉",
                description: "如欲使用此定位功能，請至系統設定開啟此應用的定位服務。",
                buttonText: "開啟系統設定",
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
                    Text(allStops.isEmpty ? "正在載入巴士站數據庫..." : "正在尋找您的位置...")
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
                    Text("附近未發現巴士站。")
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
                    renderByStationName() // <--- NEW
                } else {
                    renderFlatList()
                }
            }
        }
    }
    
    // MARK: - View Builders
    
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
                        Text("目前無即時抵達班次或路線")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(stopModel.routes) { route in
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
            if flatRoutes.isEmpty {
                Text("目前無即時抵達班次或路線")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(flatRoutes, id: \.route.id) { item in
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
                        
                        routeRow(route: item.route, stopInfo: item.stop)
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
                        Text("沒有班次")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        // 1. OUTBOUND FIRST (No Text Label)
                        ForEach(group.outbound, id: \.route.id) { item in
                            routeRowWithStationNumber(route: item.route, stopInfo: item.stopInfo)
                        }
                        
                        // 2. INBOUND SECOND (No Text Label)
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
        Button(action: {
            onRouteSelected(route, stopInfo)
        }) {
            HStack(alignment: .center, spacing: 12) {
                Text(route.route)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 64, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.65, green: 0.08, blue: 0.12))
                    )
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("往")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(route.destNameTc)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    
                    // <--- FIXED: Now safely extracting "TY980" or "T46" from the raw name
                    Text(extractPoleId(from: stopInfo.name_tc))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // ETA Logic
                HStack(spacing: 6) {
                    if let firstEta = route.etas.first, let etaDate = firstEta.etaDate {
                        let secondsLeft = etaDate.timeIntervalSince(currentTime)
                        let minutesLeft = Int(secondsLeft / 60)
                        if(minutesLeft < 0){
                            Text("遲到 \(minutesLeft * -1) 分鐘") // Localized for consistency
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(Color.red)
                        }
                        else if(minutesLeft == 0){
                            Text("即將抵達")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(Color.green)
                        }
                        else{
                            Text("\(minutesLeft) 分鐘")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                        }
                    } else {
                        Text("沒有班次")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let firstEtaDate = route.etas.first?.etaDate,
               firstEtaDate.timeIntervalSince(currentTime) > 120 {
                Button {
                    onSetTimer(route, stopInfo)
                } label: {
                    Label("提示", systemImage: "bell.fill")
                }
                .tint(.blue)
            }
        }
    }
    
    @ViewBuilder
    private func routeRow(route: NearbyRouteModel, stopInfo: StopInfo) -> some View {
        Button(action: {
            onRouteSelected(route, stopInfo)
        }) {
            HStack(alignment: .center, spacing: 12) {
                Text(route.route)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 64, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.65, green: 0.08, blue: 0.12))
                    )
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("往")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(route.destNameTc)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    if let firstEta = route.etas.first, let etaDate = firstEta.etaDate {
                        let secondsLeft = etaDate.timeIntervalSince(currentTime)
                        let minutesLeft = Int(secondsLeft / 60)
                        if(minutesLeft < 0){
                            Text("遲到 \(minutesLeft * -1) 分鐘")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(Color.red)
                        }
                        else if(minutesLeft == 0){
                            Text("即將到站")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(Color.green)
                        }
                        else{
                            Text("\(minutesLeft) 分鐘")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(.primary)
                        }
                    } else {
                        Text("無即時班次")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let firstEtaDate = route.etas.first?.etaDate,
               firstEtaDate.timeIntervalSince(currentTime) > 120 {
                Button {
                    onSetTimer(route, stopInfo)
                } label: {
                    Label("提醒", systemImage: "bell.fill")
                }
                .tint(.blue)
            }
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
        // Finds the last "(" and ")" in strings like "屯門公路轉車站 (T46)"
        if let lastOpen = rawName.lastIndex(of: "("),
           let lastClose = rawName.lastIndex(of: ")"),
           lastOpen < lastClose {
            
            let idString = rawName[rawName.index(after: lastOpen)..<lastClose]
            return String(idString)
        }
        
        // Fallback if no parentheses are found
        return "N/A"
    }
}

