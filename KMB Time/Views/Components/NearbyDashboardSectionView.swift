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
    
    let allRoutes: [RouteSuggestion]
    
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
        
        for stopModel in visibleNearbyStops {
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
    
    private var visibleNearbyStops: [NearbyStopModel] {
        nearbyStops.filter { shouldDisplayStop($0) }
    }
    
    var groupedByStationName: [StationNameGroup] {
        var dict: [String: StationNameGroup] = [:]
        
        for stopModel in visibleNearbyStops {
            let rawName = stopModel.stopInfo.name_tc
            let cleanName = normalizedStationName(rawName)
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
    
    // MARK: - Renderers
    
    @ViewBuilder
    private func renderByStation() -> some View {
        ForEach(visibleNearbyStops) { stopModel in
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
            let uniqueRoutes = flatRoutes.reduce(into: [String: (route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance)]()) { dict, item in
                let key = dashboardRouteDisplayKey(item.route)
                
                if let existing = dict[key] {
                    if item.route.co == "KMB+CTB", existing.route.co == BusOperator.kmb.rawValue {
                        let mergedRoute = mergedJointRoute(jointRoute: item.route, kmbRoute: existing.route)
                        dict[key] = (
                            route: mergedRoute,
                            stop: resolvedStopInfo(for: mergedRoute, fallback: existing.stop),
                            distance: min(item.distance, existing.distance)
                        )
                    } else if existing.route.co == "KMB+CTB", item.route.co == BusOperator.kmb.rawValue {
                        let mergedRoute = mergedJointRoute(jointRoute: existing.route, kmbRoute: item.route)
                        dict[key] = (
                            route: mergedRoute,
                            stop: resolvedStopInfo(for: mergedRoute, fallback: item.stop),
                            distance: min(item.distance, existing.distance)
                        )
                    } else if item.distance < existing.distance {
                        dict[key] = (
                            route: item.route,
                            stop: resolvedStopInfo(for: item.route, fallback: item.stop),
                            distance: item.distance
                        )
                    }
                } else {
                    dict[key] = (
                        route: item.route,
                        stop: resolvedStopInfo(for: item.route, fallback: item.stop),
                        distance: item.distance
                    )
                }
            }
            
            let filteredRoutes = Array(uniqueRoutes.values).sorted { a, b in
                let aHasService = !a.route.etas.isEmpty
                let bHasService = !b.route.etas.isEmpty
                
                if aHasService != bHasService {
                    return aHasService // In service comes first
                }
                
                if a.distance != b.distance {
                    return a.distance < b.distance
                }
                
                if a.route.directionCode != b.route.directionCode {
                    return a.route.directionCode == "I" // Inbound comes before Outbound
                }
                
                return a.route.route.localizedStandardCompare(b.route.route) == .orderedAscending
            }
            
            if filteredRoutes.isEmpty {
                Text("暫無服務...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(filteredRoutes, id: \.route.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        routeRowWithDetails(route: item.route, stopInfo: item.stop)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    private func dashboardRouteDisplayKey(_ route: NearbyRouteModel) -> String {
        let normalizedRoute = route.route.uppercased()
        if route.co == "KMB+CTB" {
            return "\(normalizedRoute)-\(normalizedStationName(route.destNameTc))-joint"
        }
        return "\(normalizedRoute)-\(route.directionCode)-\(route.co)"
    }
    
    private func mergedJointRoute(jointRoute: NearbyRouteModel, kmbRoute: NearbyRouteModel) -> NearbyRouteModel {
        NearbyRouteModel(
            co: "KMB+CTB",
            route: jointRoute.route,
            directionCode: jointRoute.directionCode,
            destNameTc: jointRoute.destNameTc,
            displayStopName: kmbRoute.displayStopName,
            displayStopId: kmbRoute.displayStopId,
            etas: kmbRoute.etas,
            detailDirectionCode: kmbRoute.directionCode
        )
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
    
    // MARK: - Row Components
    
    @ViewBuilder
    private func routeRowWithStationNumber(route: NearbyRouteModel, stopInfo: StopInfo) -> some View {
        let resolvedStopInfo = resolvedStopInfo(for: route, fallback: stopInfo)
        Button(action: { onRouteSelected(route, resolvedStopInfo) }) {
            HStack(alignment: .center, spacing: 12) {
                VStack(spacing: 2) {
                    Text(route.route)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(KMBRouteTheme.foregroundColor(route: route.route, company: route.co, allRoutes: allRoutes))
                        .frame(width: 52, height: 32)
                        .background(KMBRouteTheme.backgroundColor(route: route.route, company: route.co, allRoutes: allRoutes))
                        .cornerRadius(8)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("往")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(route.destNameTc)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                etaCountdownView(etas: route.etas)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private func routeRow(route: NearbyRouteModel, stopInfo: StopInfo) -> some View {
        let resolvedStopInfo = resolvedStopInfo(for: route, fallback: stopInfo)
        Button(action: { onRouteSelected(route, resolvedStopInfo) }) {
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
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                etaCountdownView(etas: route.etas)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            let dirStr = route.directionCode == "O" ? "outbound" : "inbound"
            let isFav = favoritesManager.isFavorite(route: route.route, direction: dirStr, company: route.co)
            
            Button {
                favoritesManager.toggleFavorite(route: route.route, direction: dirStr, destName: route.destNameTc, company: route.co)
                onShowToast(isFav ? "已從常用路線移除" : "已加入常用路線")
            } label: {
                Label(isFav ? "取消常用" : "加入常用", systemImage: isFav ? "star.slash" : "star.fill")
            }
            .tint(isFav ? .red : .orange)

            if route.etas.contains(where: { $0.etaDate?.timeIntervalSince(currentTime) ?? 0 > 120 }) {
                Button {
                    onSetTimer(route, resolvedStopInfo)
                } label: {
                    Label("設定提示", systemImage: "bell.fill")
                }
                .tint(.blue)
            }
        }
    }
    
    @ViewBuilder
    private func routeRowWithDetails(route: NearbyRouteModel, stopInfo: StopInfo) -> some View {
        let resolvedStopInfo = resolvedStopInfo(for: route, fallback: stopInfo)
        Button(action: { onRouteSelected(route, resolvedStopInfo) }) {
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
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill").font(.caption2).foregroundColor(.secondary)
                        Text("\(resolvedStopInfo.name_tc) • \(formatDistance(self.nearbyStops.first(where: { $0.stopInfo.stop == resolvedStopInfo.stop })?.distance ?? 0))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                etaCountdownView(etas: route.etas)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            let dirStr = route.directionCode == "O" ? "outbound" : "inbound"
            let isFav = favoritesManager.isFavorite(route: route.route, direction: dirStr, company: route.co)
            
            Button {
                favoritesManager.toggleFavorite(route: route.route, direction: dirStr, destName: route.destNameTc, company: route.co)
                onShowToast(isFav ? "已從常用路線移除" : "已加入常用路線")
            } label: {
                Label(isFav ? "取消常用" : "加入常用", systemImage: isFav ? "star.slash" : "star.fill")
            }
            .tint(isFav ? .red : .orange)

            if route.etas.contains(where: { $0.etaDate?.timeIntervalSince(currentTime) ?? 0 > 120 }) {
                Button {
                    onSetTimer(route, resolvedStopInfo)
                } label: {
                    Label("設定提示", systemImage: "bell.fill")
                }
                .tint(.blue)
            }
        }
    }

    @ViewBuilder
    private func companyTagView(route: NearbyRouteModel) -> some View {
        VStack(spacing: 2) {
            Text(route.route)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(KMBRouteTheme.foregroundColor(route: route.route, company: route.co, allRoutes: allRoutes))
                .frame(width: 52, height: 32)
                .background(KMBRouteTheme.backgroundColor(route: route.route, company: route.co, allRoutes: allRoutes))
                .cornerRadius(8)
        }
    }
    
    @ViewBuilder
    private func timerBellView() -> some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 14))
            .foregroundColor(.yellow)
            .padding(6)
            .background(Circle().fill(Color.yellow.opacity(0.2)))
    }
    
    // MARK: - Local Helpers
    
    private func shouldDisplayStop(_ stopModel: NearbyStopModel) -> Bool {
        !(stopModel.hasFetchedRoutes && stopModel.routes.isEmpty)
    }
    
    private func relativeTimeText(for etas: [ETADisplayInfo]) -> (text: String, color: Color) {
        guard let firstEta = etas.first?.etaDate else {
            return ("沒有班次", .secondary)
        }
        
        let diff = firstEta.timeIntervalSince(currentTime)
        if diff < 60 {
            return ("即將抵達", .red)
        } else {
            let minutes = Int(diff / 60)
            return ("\(minutes) 分鐘", .primary)
        }
    }
    
    @ViewBuilder
    private func etaCountdownView(etas: [ETADisplayInfo]) -> some View {
        let etaInfo = relativeTimeText(for: etas)
        Text(etaInfo.text)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(etaInfo.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(etaInfo.color.opacity(0.1))
            .cornerRadius(6)
    }
    
    private func toggleStopExpanded(_ stopId: String) {
        if expandedStopIds.contains(stopId) {
            expandedStopIds.remove(stopId)
        } else {
            expandedStopIds.insert(stopId)
        }
    }
    
    private func resolvedStopInfo(for route: NearbyRouteModel, fallback: StopInfo) -> StopInfo {
        guard let displayStopId = route.displayStopId else { return fallback }
        if let stopModel = nearbyStops.first(where: { $0.stopInfo.stop == displayStopId }) {
            return stopModel.stopInfo
        }
        return StopInfo(
            stop: displayStopId,
            name_tc: route.displayStopName ?? fallback.name_tc,
            lat: fallback.lat,
            long: fallback.long
        )
    }
    
    private func normalizedStationName(_ stopName: String) -> String {
        let withoutPoleId = stopName.replacingOccurrences(
            of: "\\s*\\(([A-Z]{1,4}\\d{1,4}|[A-Z]\\d{1,5}|\\d{1,5})\\)\\s*$",
            with: "",
            options: .regularExpression
        )
        let baseName = withoutPoleId
            .split(whereSeparator: { $0 == "，" || $0 == "," })
            .first
            .map(String.init) ?? withoutPoleId
        return baseName.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let match = rawName.range(
            of: "\\(([A-Z]{1,4}\\d{1,4}|[A-Z]\\d{1,5}|\\d{1,5})\\)\\s*$",
            options: .regularExpression
        ) else {
            return "N/A"
        }
        return String(rawName[match])
            .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
    }
}
