/// 檔案用途：連接首頁 UI 操作同 ContentView 狀態。

import SwiftUI
import CoreLocation

/// `NearbyDashboardSectionView` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct NearbyDashboardSectionView: View {
    @EnvironmentObject var favoritesManager: FavoritesManager
    
    @ObservedObject var locationManager: LocationManager
    let allStops: [StopInfo]
    let nearbyStops: [NearbyStopModel]
    let currentTime: Date
    
    let allRoutes: [RouteSuggestion]
    
    let onRequestLocation: () -> Void
    let onRouteSelected: (NearbyRouteModel, StopInfo) -> Void
    let onSetTimer: (NearbyRouteModel, StopInfo) -> Void
    let onShowToast: (String) -> Void
    
    // MARK: - Sorting Helpers
    
    /// 按畫面需要排序並回傳結果。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
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
    
    private var visibleNearbyStops: [NearbyStopModel] {
        nearbyStops.filter { shouldDisplayStop($0) }
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
                    Text("附近沒有巴士站")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                renderFlatList()
            }
        }
    }
    
    // MARK: - Renderers
    
    @ViewBuilder
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
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
                pendingStopRows()
            } else {
                ForEach(filteredRoutes, id: \.route.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        routeRowWithDetails(route: item.route, stopInfo: item.stop)
                    }
                }
            }
        }
        .alignedListSectionMargins(horizontal: 16)
    }
    
    @ViewBuilder
    /// Show route-shaped placeholders while nearby route ETA requests are still in progress.
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func pendingStopRows() -> some View {
        let pendingCount = nearbyStops.contains { !$0.hasFetchedRoutes } ? 6 : 0
        if pendingCount == 0 {
            Text("暫無服務...")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(0..<pendingCount, id: \.self) { _ in
                routeSkeletonRow()
            }
        }
    }
    
    @ViewBuilder
    /// Render a skeleton row with the same shape as a loaded nearby route row.
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func routeSkeletonRow() -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 64, height: 52)
                .overlay {
                    Text("路線")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.55))
                }
            
            VStack(alignment: .leading, spacing: 6) {
                skeletonBar(width: 120, height: 14)
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.45))
                    skeletonBar(width: 150, height: 10)
                }
                skeletonBar(width: 54, height: 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            etaLoadingMaskView()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.35))
        }
    }
    
    /// Draw one rounded placeholder bar for skeleton rows.
    /// - Parameters:
    ///   - width: Bar width.
    ///   - height: Bar height.
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .frame(width: width, height: height)
    }
    
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    /// - Returns: 格式化或查找後嘅文字。
    private func dashboardRouteDisplayKey(_ route: NearbyRouteModel) -> String {
        let normalizedRoute = route.route.uppercased()
        if route.co == "KMB+CTB" {
            return "\(normalizedRoute)-\(normalizedStationName(route.destNameTc))-joint"
        }
        return "\(normalizedRoute)-\(route.directionCode)-\(route.co)"
    }
    
    /// 合併多個資料來源並回傳統一結果。
    /// - Parameters:
    ///   - jointRoute: 路線編號或路線模型。
    ///   - kmbRoute: 路線編號或路線模型。
    /// - Returns: 計算後嘅 `NearbyRouteModel`。
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
    
    // MARK: - Row Components
    
    @ViewBuilder
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - stopInfo: 車站識別或車站資料。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
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
                    
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(resolvedStopInfo.name_tc)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(formatDistance(distance(for: resolvedStopInfo)))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
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
    /// 整理或查找巴士公司顯示資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func companyTagView(route: NearbyRouteModel) -> some View {
        Text(route.route)
            .font(.system(.body, design: .rounded))
            .fontWeight(.bold)
            .foregroundColor(KMBRouteTheme.foregroundColor(route: route.route, company: route.co, allRoutes: allRoutes))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: 64, height: 52)
            .background(RoundedRectangle(cornerRadius: 8).fill(KMBRouteTheme.backgroundColor(route: route.route, company: route.co, allRoutes: allRoutes)))
    }
    
    // MARK: - Local Helpers
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - stopModel: 車站識別或車站資料。
    /// - Returns: 條件是否成立。
    private func shouldDisplayStop(_ stopModel: NearbyStopModel) -> Bool {
        !(stopModel.hasFetchedRoutes && stopModel.routes.isEmpty)
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - color: 畫面顏色。
    /// - Returns: 格式化或查找後嘅文字。
    private func relativeTimeText(for etas: [ETADisplayInfo]) -> (text: String, color: Color) {
        guard let firstEta = etas
            .compactMap(\.etaDate)
            .first(where: { $0 >= currentTime.addingTimeInterval(-60) }) else {
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
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - etas: 時間或到站時間資料。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
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
    
    @ViewBuilder
    /// 顯示 ETA 載入中狀態，避免空白或誤會為沒有班次。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func etaLoadingMaskView() -> some View {
        Text("載入中")
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.8)
            )
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - fallback: 此函式需要嘅輸入資料。
    /// - Returns: 計算後嘅 `StopInfo`。
    private func resolvedStopInfo(for route: NearbyRouteModel, fallback: StopInfo) -> StopInfo {
        if route.co == "KMB+CTB", let kmbStop = nearbyKMBStopForJointRoute(route, fallback: fallback) {
            return kmbStop
        }
        
        guard let displayStopId = route.displayStopId else { return fallback }
        let preferredOperator = operatorCode(for: route, fallback: fallback.operatorCode)
        if let stopModel = nearbyStops.first(where: { $0.stopInfo.stop == displayStopId && $0.stopInfo.operatorCode == preferredOperator }) {
            return stopModel.stopInfo
        }
        if let stopModel = nearbyStops.first(where: { $0.stopInfo.stop == displayStopId }) {
            return stopModel.stopInfo
        }
        return StopInfo(
            stop: displayStopId,
            name_tc: route.displayStopName ?? fallback.name_tc,
            lat: fallback.lat,
            long: fallback.long,
            operatorCode: preferredOperator
        )
    }
    
    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    /// - Returns: 可用嘅位置資料；沒有時為 nil。
    private func distance(for stopInfo: StopInfo) -> CLLocationDistance {
        nearbyStops.first { $0.stopInfo.identityKey == stopInfo.identityKey }?.distance
            ?? nearbyStops.first { $0.stopInfo.stop == stopInfo.stop }?.distance
            ?? 0
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - fallback: 此函式需要嘅輸入資料。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    private func nearbyKMBStopForJointRoute(_ route: NearbyRouteModel, fallback: StopInfo) -> StopInfo? {
        if fallback.operatorCode == .kmb {
            return fallback
        }
        
        guard let fallbackLocation = fallback.clLocation else { return nil }
        let kmbCandidates = nearbyStops.filter { $0.stopInfo.operatorCode == .kmb }
        let routeServingStops = kmbCandidates.filter { stopModel in
            guard let stopLocation = stopModel.stopInfo.clLocation,
                  fallbackLocation.distance(from: stopLocation) <= 150 else {
                return false
            }
            return stopModel.routes.contains { candidate in
                candidate.route.uppercased() == route.route.uppercased() &&
                candidate.directionCode == route.directionCode &&
                (candidate.co == "KMB+CTB" || candidate.co == BusOperator.kmb.rawValue)
            }
        }
        if let routeServingStop = routeServingStops.min(by: { first, second in
            let firstDistance = first.stopInfo.clLocation.map { fallbackLocation.distance(from: $0) } ?? .infinity
            let secondDistance = second.stopInfo.clLocation.map { fallbackLocation.distance(from: $0) } ?? .infinity
            return firstDistance < secondDistance
        }) {
            return routeServingStop.stopInfo
        }
        let nearestStop = kmbCandidates.min { first, second in
            let firstDistance = first.stopInfo.clLocation.map { fallbackLocation.distance(from: $0) } ?? .infinity
            let secondDistance = second.stopInfo.clLocation.map { fallbackLocation.distance(from: $0) } ?? .infinity
            return firstDistance < secondDistance
        }
        guard let nearestStop,
              let nearestLocation = nearestStop.stopInfo.clLocation,
              fallbackLocation.distance(from: nearestLocation) <= 150 else {
            return nil
        }
        return nearestStop.stopInfo
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - fallback: 此函式需要嘅輸入資料。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    private func operatorCode(for route: NearbyRouteModel, fallback: BusOperator?) -> BusOperator? {
        switch route.co {
        case BusOperator.kmb.rawValue:
            return .kmb
        case BusOperator.ctb.rawValue:
            return .ctb
        default:
            return fallback
        }
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - stopName: 車站識別或車站資料。
    /// - Returns: 格式化或查找後嘅文字。
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
    
    /// 將資料格式化成畫面顯示文字。
    /// - Parameters:
    ///   - distance: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    private func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return String(format: "%.0f 米", distance)
        } else {
            return String(format: "%.1f 公里", distance / 1000)
        }
    }
    
    @ViewBuilder
    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - icon: 此函式需要嘅輸入資料。
    ///   - color: 畫面顏色。
    ///   - title: 畫面顯示文字。
    ///   - description: 此函式需要嘅輸入資料。
    ///   - buttonText: 畫面顯示文字。
    ///   - action: 需要執行嘅 callback 或建立資料嘅 closure。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
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
}
