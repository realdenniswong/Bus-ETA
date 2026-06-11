/// 檔案用途：連接首頁 UI 操作同 ContentView 狀態。

import SwiftUI
import CoreLocation

/// `NearbyDashboardSectionView` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct NearbyDashboardSectionView: View {
    @EnvironmentObject var favoritesManager: FavoritesManager

    private struct DashboardRouteRow: Identifiable {
        let id: String
        let route: NearbyRouteModel
        let stop: StopInfo
    }

    @ObservedObject var locationManager: LocationManager
    let allStops: [StopInfo]
    let nearbyStops: [NearbyStopModel]
    let currentTime: Date

    let allRoutes: [RouteSuggestion]

    let onRequestLocation: () -> Void
    let onRouteSelected: (NearbyRouteModel, StopInfo) -> Void
    let onSetTimer: (NearbyRouteModel, StopInfo) -> Void
    let onShowToast: (String) -> Void

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

    // MARK: - 渲染器

    @ViewBuilder
    /// 渲染攤平後嘅附近路線列表，並合併重複嘅 KMB 同聯營路線項目。
    /// - Returns: 包含已載入路線列或載入 placeholder 嘅列表 section。
    private func renderFlatList() -> some View {
        Section {
            let uniqueRoutes = flatRoutes.reduce(into: [String: (route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance)]()) { dict, item in
                let matchingKey = dict.keys.first { key in
                    guard let existing = dict[key] else { return false }
                    return dashboardRoutesRepresentSameRow(existing.route, item.route)
                }
                let key = matchingKey ?? dashboardRouteDisplayKey(item.route)

                if let existing = dict[key] {
                    dict[key] = mergedDashboardRoute(existing: existing, candidate: item)
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
                    return aHasService // 有服務嘅路線排先
                }

                if a.distance != b.distance {
                    return a.distance < b.distance
                }

                if a.route.directionCode != b.route.directionCode {
                    return a.route.directionCode == "I" // 回程排喺去程前
                }

                return a.route.route.localizedStandardCompare(b.route.route) == .orderedAscending
            }

            if filteredRoutes.isEmpty {
                pendingStopRows()
            } else {
                let displayRows = filteredRoutes.map { item in
                    DashboardRouteRow(
                        id: dashboardRowID(route: item.route),
                        route: item.route,
                        stop: item.stop
                    )
                }
                ForEach(displayRows) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        routeRowWithDetails(route: item.route, stopInfo: item.stop)
                    }
                }
            }
        }
        .alignedListSectionMargins(horizontal: 16)
    }

    @ViewBuilder
    /// 附近路線 ETA 請求仍在進行時顯示 placeholder。
    /// - Returns: 請求未完成時返回 skeleton 列；載入完成但無路線時返回無服務訊息。
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
    /// 渲染同已載入附近路線列視覺形狀一致嘅 skeleton 列。
    /// - Returns: Placeholder 路線標籤、站點文字條、ETA mask 同 disclosure 圖示。
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

    /// 為 skeleton 列繪製一條圓角 placeholder 條。
    /// - Parameters:
    ///   - width: 條形寬度，單位為 points。
    ///   - height: 條形高度，單位為 points。
    /// - Returns: 符合 skeleton 版面尺寸嘅圓角矩形。
    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .frame(width: width, height: height)
    }

    /// 建立附近路線列嘅顯示去重 key。
    /// - Parameter route: 來自攤平站點列表嘅附近路線候選項目。
    /// - Returns: 聯營路線按路線同標準化目的地分組、一般路線按路線、方向同營辦商分組嘅 key。
    private func dashboardRouteDisplayKey(_ route: NearbyRouteModel) -> String {
        let normalizedRoute = route.route.uppercased()
        if route.co == "KMB+CTB" {
            return "\(normalizedRoute)-\(normalizedStationName(route.destNameTc))-joint"
        }
        return "\(normalizedRoute)-\(route.directionCode)-\(route.co)"
    }

    /// 建立穩定嘅首頁列身份，避免每秒重繪時關閉 swipe actions。
    /// - Parameter route: 要顯示嘅附近路線。
    /// - Returns: 不依賴 `NearbyRouteModel.id` UUID 嘅穩定列 key。
    private func dashboardRowID(route: NearbyRouteModel) -> String {
        let normalizedRoute = route.route.uppercased()
        if route.co == "KMB+CTB" {
            return "\(normalizedRoute)-\(route.directionCode)-\(normalizedStationName(route.destNameTc))-joint"
        }
        return "\(normalizedRoute)-\(route.directionCode)-\(route.co)"
    }

    /// 判斷兩個附近路線候選是否代表首頁同一條顯示列。
    /// - Parameters:
    ///   - lhs: 已收集嘅候選路線。
    ///   - rhs: 新讀取到嘅候選路線。
    /// - Returns: 同一路線、方向或目的地嘅聯營候選會合併為一列。
    private func dashboardRoutesRepresentSameRow(_ lhs: NearbyRouteModel, _ rhs: NearbyRouteModel) -> Bool {
        if dashboardRouteDisplayKey(lhs) == dashboardRouteDisplayKey(rhs) {
            return true
        }

        let includesJointRoute = lhs.co == "KMB+CTB" || rhs.co == "KMB+CTB"
        guard includesJointRoute,
              lhs.route.uppercased() == rhs.route.uppercased() else {
            return false
        }

        return lhs.directionCode == rhs.directionCode ||
            normalizedStationName(lhs.destNameTc) == normalizedStationName(rhs.destNameTc)
    }

    /// 合併兩個首頁候選列，並讓最快可用 ETA 排到第一。
    /// - Parameters:
    ///   - existing: 字典入面已保留嘅候選列。
    ///   - candidate: 新讀取到、代表同一路線嘅候選列。
    /// - Returns: 包含合併 ETA、營辦商站點 id 同較佳顯示站點嘅首頁列。
    private func mergedDashboardRoute(
        existing: (route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance),
        candidate: (route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance)
    ) -> (route: NearbyRouteModel, stop: StopInfo, distance: CLLocationDistance) {
        let useCandidateStop = candidate.distance < existing.distance
        let fallbackStop = useCandidateStop ? candidate.stop : existing.stop
        let mergedRoute: NearbyRouteModel

        if existing.route.co == "KMB+CTB", candidate.route.co == BusOperator.kmb.rawValue {
            mergedRoute = mergedJointRoute(jointRoute: existing.route, otherRoute: candidate.route)
        } else if candidate.route.co == "KMB+CTB", existing.route.co == BusOperator.kmb.rawValue {
            mergedRoute = mergedJointRoute(jointRoute: candidate.route, otherRoute: existing.route)
        } else if existing.route.co == "KMB+CTB" || candidate.route.co == "KMB+CTB" {
            let jointRoute = existing.route.co == "KMB+CTB" ? existing.route : candidate.route
            let otherRoute = existing.route.co == "KMB+CTB" ? candidate.route : existing.route
            mergedRoute = mergedJointRoute(jointRoute: jointRoute, otherRoute: otherRoute)
        } else if useCandidateStop {
            mergedRoute = candidate.route
        } else {
            mergedRoute = existing.route
        }

        return (
            route: mergedRoute,
            stop: resolvedStopInfo(for: mergedRoute, fallback: fallbackStop),
            distance: min(existing.distance, candidate.distance)
        )
    }

    /// 當 KMB-only 結果需要代表 KMB/CTB 聯營路線時，建立對應列模型。
    /// - Parameters:
    ///   - jointRoute: 由聯營 provider 解析出嚟嘅聯營路線 metadata。
    ///   - otherRoute: 同一路線嘅 KMB 或 CTB 候選，會提供額外 ETA 同站點 id。
    /// - Returns: 顯示聯營品牌、並按最快 ETA 排序嘅 `KMB+CTB` 列。
    private func mergedJointRoute(jointRoute: NearbyRouteModel, otherRoute: NearbyRouteModel) -> NearbyRouteModel {
        let mergedETAs = sortedDashboardETAs(jointRoute.etas + otherRoute.etas)
        let displayStopName = jointRoute.displayStopName ?? otherRoute.displayStopName
        let displayStopId = jointRoute.displayStopId ?? otherRoute.displayStopId
        return NearbyRouteModel(
            co: "KMB+CTB",
            route: jointRoute.route,
            directionCode: jointRoute.directionCode,
            destNameTc: jointRoute.destNameTc,
            displayStopName: displayStopName,
            displayStopId: displayStopId,
            etas: Array(mergedETAs.prefix(3)),
            detailDirectionCode: jointRoute.detailDirectionCode ?? jointRoute.directionCode,
            operatorStopIds: jointRoute.operatorStopIds.merging(otherRoute.operatorStopIds) { _, new in new }
        )
    }

    // MARK: - 列元件

    @ViewBuilder
    /// 渲染一列附近路線，包含目的地、已解析站點、距離、ETA 同滑動操作。
    /// - Parameters:
    ///   - route: 要顯示並喺點擊時開啟嘅附近路線。
    ///   - stopInfo: 路線無提供更具體顯示站點時使用嘅後備站點。
    /// - Returns: 可點擊列，並喺可用時提供收藏同計時器滑動操作。
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
    /// 使用營辦商專用路線配色主題渲染固定尺寸路線徽章。
    /// - Parameter route: 路線號碼同營辦商會決定徽章文字同顏色嘅附近路線。
    /// - Returns: 每列附近路線左側使用嘅路線徽章。
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

    // MARK: - 本地輔助方法

    /// 決定附近站點喺路線請求完成後是否仍然顯示。
    /// - Parameter stopModel: 首頁列表中嘅附近站點列狀態。
    /// - Returns: 只有當站點已完成載入而且無可顯示途經路線時，先返回 `false`。
    private func shouldDisplayStop(_ stopModel: NearbyStopModel) -> Bool {
        !(stopModel.hasFetchedRoutes && stopModel.routes.isEmpty)
    }

    /// 將下一個可用 ETA 轉成附近列顯示嘅短倒數標籤。
    /// - Parameter etas: 附加喺路線上、按 provider 回應排序嘅 ETA 值。
    /// - Returns: 無服務、即將抵達或分鐘倒數狀態對應嘅顯示文字同顏色。
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

    /// 按實際到站時間整理首頁已合併嘅 ETA 候選。
    /// - Parameter etas: 來自 KMB、CTB 或聯營候選列嘅 ETA。
    /// - Returns: 已移除過期 ETA 並由快至慢排序嘅結果。
    private func sortedDashboardETAs(_ etas: [ETADisplayInfo]) -> [ETADisplayInfo] {
        let staleETAThreshold = currentTime.addingTimeInterval(-60)
        return etas
            .filter { ($0.etaDate ?? Date.distantPast) >= staleETAThreshold }
            .sorted { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
    }

    @ViewBuilder
    /// 為附近路線列渲染圓角 ETA 倒數 pill。
    /// - Parameter etas: 用嚟推算 pill 標籤同顏色嘅 ETA 值。
    /// - Returns: 顯示下一班到站狀態嘅精簡文字徽章。
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
    /// 顯示 ETA 載入徽章，避免待載入列被誤以為係無服務路線。
    /// - Returns: Skeleton 列入面使用嘅低調 `載入中` pill。
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

    /// 從附近路線列開啟詳情或設定計時器時，解析應該使用嘅站點。
    /// - Parameters:
    ///   - route: 顯示站點可能同原本列站點不同嘅附近路線。
    ///   - fallback: 找不到更好顯示站點時使用、來自攤平附近列表嘅站點。
    /// - Returns: 最適合路線詳情同計時器設定使用嘅站點資料。
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

    /// 尋找附近列中顯示站點嘅快取距離。
    /// - Parameter stopInfo: 站名下方需要顯示距離嘅站點。
    /// - Returns: 以米為單位嘅距離；站點不存在於 `nearbyStops` 時返回 `0`。
    private func distance(for stopInfo: StopInfo) -> CLLocationDistance {
        nearbyStops.first { $0.stopInfo.identityKey == stopInfo.identityKey }?.distance
            ?? nearbyStops.first { $0.stopInfo.stop == stopInfo.stop }?.distance
            ?? 0
    }

    /// 當聯營路線係從 CTB 站點發現時，尋找最近可用嘅 KMB 站點。
    /// - Parameters:
    ///   - route: 路線詳情需要 KMB 站點嘅聯營附近路線。
    ///   - fallback: 列中原本附近站點；如果已經係 KMB 站點就直接使用。
    /// - Returns: 成功配對時返回 150 米內嘅附近 KMB 站點，否則返回 `nil`。
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

    /// 建立顯示站點資料時，解析附近路線嘅實際營辦商。
    /// - Parameters:
    ///   - route: `co` 字串可能代表 KMB、CTB 或聯營路線嘅附近路線。
    ///   - fallback: 後備站點嘅營辦商，會保留畀聯營路線使用。
    /// - Returns: `.kmb`、`.ctb`，或聯營／未知路線代碼嘅後備營辦商。
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

    /// 比較聯營路線目的地前，先標準化站名。
    /// - Parameter stopName: 可能包含站柱編號或逗號分隔尾段嘅原始站名。
    /// - Returns: 已移除尾段站柱 metadata 嘅基本站名。
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

    /// 格式化站點距離，供站名下方顯示。
    /// - Parameter distance: 以米為單位嘅距離。
    /// - Returns: 1 公里以下返回米字串；1 公里或以上返回一位小數公里字串。
    private func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return String(format: "%.0f 米", distance)
        } else {
            return String(format: "%.1f 公里", distance / 1000)
        }
    }

    @ViewBuilder
    /// 渲染附近首頁嘅權限或位置錯誤狀態。
    /// - Parameters:
    ///   - icon: 顯示喺訊息上方嘅 SF Symbol 名稱。
    ///   - color: 圖示同操作按鈕嘅強調顏色。
    ///   - title: 主要狀態訊息。
    ///   - description: 解釋使用者應該點做嘅輔助文字。
    ///   - buttonText: 操作按鈕標籤。
    ///   - action: 點擊操作按鈕時呼叫嘅 callback。
    /// - Returns: 位置權限狀態使用嘅置中卡片。
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
