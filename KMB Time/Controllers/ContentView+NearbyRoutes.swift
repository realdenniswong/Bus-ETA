/// 檔案用途：根據使用者位置計算附近站點同即時附近路線 ETA。
import CoreLocation

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 根據目前位置重新計算附近站點，並為可見列開始載入 ETA。
    /// - Parameter userLocation: 目前裝置位置，用嚟篩選首頁半徑內嘅站點。
    func updateNearbyStops(userLocation: CLLocation) async {
        let stepStart = Date()
        guard !allStops.isEmpty else { return }

        let shouldStartUpdate = await MainActor.run {
            guard !isUpdatingNearby else { return false }
            isUpdatingNearby = true
            isSearchingNearby = true
            return true
        }
        guard shouldStartUpdate else { return }

        let dashboardStops = nearbyStopModels(from: allStops, userLocation: userLocation, radius: 300)
        logTiming("nearby stop search", startedAt: stepStart, detail: "\(dashboardStops.count) stops")

        await MainActor.run {
            self.nearbyStops = dashboardStops
            self.isSearchingNearby = false
        }
        logTiming("nearby UI update", startedAt: stepStart)

        await progressivelyFetchRoutes(for: dashboardStops)
    }

    /// 強制目前顯示嘅附近站點重新載入路線 ETA。
    ///
    /// 現有附近站點列會保留喺畫面上，而 ETA 請求會略過首頁短期快取。
    func refreshNearbyETAs() async {
        guard !nearbyStops.isEmpty else { return }
        await MainActor.run { isSearchingNearby = true }
        await progressivelyFetchRoutes(for: nearbyStops, forceRefresh: true)
    }

    /// 以小批次擷取附近路線 ETA，並喺每個站點完成後即時發布。
    /// - Parameters:
    ///   - stops: 已顯示喺畫面上嘅附近候選站點。
    ///   - forceRefresh: 是否略過短期 ETA 快取。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func progressivelyFetchRoutes(for stops: [NearbyStopModel], forceRefresh: Bool = false) async {
        let routeStart = Date()
        let sortedStops = stops.sorted { $0.distance < $1.distance }
        let visibleStops = Array(sortedStops.prefix(8))
        let deferredStops = Array(sortedStops.dropFirst(8).prefix(12))

        await fetchRouteBatches(for: visibleStops, forceRefresh: forceRefresh, concurrencyLimit: 4)
        logTiming("visible ETA fetching", startedAt: routeStart, detail: "\(visibleStops.count) stops")

        if !deferredStops.isEmpty {
            await fetchRouteBatches(for: deferredStops, forceRefresh: forceRefresh, concurrencyLimit: 2)
            logTiming("deferred ETA fetching", startedAt: routeStart, detail: "\(deferredStops.count) stops")
        }

        await MainActor.run {
            self.isSearchingNearby = false
            self.isUpdatingNearby = false
        }
    }

    /// 用受限制嘅並行 API 請求數量擷取路線資料。
    /// - Parameters:
    ///   - stops: 要擷取嘅站點。
    ///   - forceRefresh: 是否略過短期 ETA 快取。
    ///   - concurrencyLimit: 最大並行站點擷取數量。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func fetchRouteBatches(for stops: [NearbyStopModel], forceRefresh: Bool, concurrencyLimit: Int) async {
        guard !stops.isEmpty else { return }
        let batches = stride(from: 0, to: stops.count, by: concurrencyLimit).map {
            Array(stops[$0..<min($0 + concurrencyLimit, stops.count)])
        }

        for batch in batches {
            await withTaskGroup(of: NearbyStopModel.self) { group in
                for stop in batch {
                    group.addTask {
                        let startedAt = Date()
                        var stopWithRoutes = stop
                        stopWithRoutes.routes = await fetchRoutesForNearbyStop(stop.stopInfo, forceRefresh: forceRefresh)
                        stopWithRoutes.hasFetchedRoutes = true
                        logTiming("ETA fetching", startedAt: startedAt, detail: stop.stopInfo.name_tc)
                        return stopWithRoutes
                    }
                }

                for await stopWithRoutes in group {
                    await applyNearbyStopRoutes(stopWithRoutes)
                }
            }
        }
    }

    /// 單一附近站點 ETA 請求完成後，更新對應站點列。
    /// - Parameters:
    ///   - stop: 更新後嘅站點模型。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func applyNearbyStopRoutes(_ stop: NearbyStopModel) async {
        let updateStart = Date()
        await MainActor.run {
            guard let index = self.nearbyStops.firstIndex(where: { $0.stopInfo.identityKey == stop.stopInfo.identityKey }) else { return }
            self.nearbyStops[index] = stop
        }
        logTiming("UI update", startedAt: updateStart, detail: stop.stopInfo.name_tc)
    }

    /// 為單一站點擷取附近路線列同 ETA 資料。
    /// - Parameters:
    ///   - stopInfo: 需要載入途經路線嘅站點。
    ///   - forceRefresh: 為 `true` 時略過首頁 ETA 快取。
    /// - Returns: 按路線號碼同方向排序、並附有快取或最新 ETA 資料嘅附近路線。
    func fetchRoutesForNearbyStop(_ stopInfo: StopInfo, forceRefresh: Bool = false) async -> [NearbyRouteModel] {
        let routes: [NearbyRouteModel]
        switch stopInfo.operatorCode {
        case .kmb:
            async let kmbRoutes = (try? kmbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            async let jointRoutes = (try? jointRouteETAProvider.fetchNearbyRoutes(for: stopInfo)) ?? []
            async let ctbRoutes = ctbDashboardRoutes(near: stopInfo, jointOnly: true)
            routes = dashboardRoutes(kmbRoutes: await kmbRoutes, ctbRoutes: await ctbRoutes, jointRoutes: await jointRoutes)
        case .ctb:
            let ctbRoutes = (try? await ctbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            routes = dashboardRoutes(kmbRoutes: [], ctbRoutes: ctbRoutes, jointRoutes: [])
        case nil:
            async let kmbRoutes = (try? kmbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            async let jointRoutes = (try? jointRouteETAProvider.fetchNearbyRoutes(for: stopInfo)) ?? []
            async let ctbRoutes = ctbDashboardRoutes(near: stopInfo)
            routes = dashboardRoutes(kmbRoutes: await kmbRoutes, ctbRoutes: await ctbRoutes, jointRoutes: await jointRoutes)
        }
        let routesWithCachedETAs = await cachedRoutes(routes, stopId: stopInfo.identityKey, forceRefresh: forceRefresh)
        return routesWithCachedETAs.sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }

    /// 將 provider 結果合併成單一附近站點顯示嘅路線集合。
    /// - Parameters:
    ///   - kmbRoutes: 該站點返回嘅 KMB 專屬附近路線。
    ///   - ctbRoutes: 該站點返回嘅 CTB 附近路線。
    ///   - jointRoutes: 從 KMB 站點脈絡解析出嚟嘅 KMB/CTB 聯營路線。
    /// - Returns: KMB 專屬路線、聯營路線同 CTB 路線；跨站點重複項目會喺 dashboard 顯示層合併 ETA。
    private func dashboardRoutes(kmbRoutes: [NearbyRouteModel], ctbRoutes: [NearbyRouteModel], jointRoutes: [NearbyRouteModel]) -> [NearbyRouteModel] {
        let kmbOnlyRoutes = kmbRoutes.filter { route in
            !ctbETAProvider.isJointRoute(route: route.route, direction: BusDirection(routeCode: route.directionCode))
        }
        return kmbOnlyRoutes + jointRoutes + ctbRoutes
    }

    /// 以站點座標查找可合併到首頁聯營列嘅 CTB 候選路線。
    /// - Parameter stopInfo: 目前載入路線嘅附近站點。
    /// - Returns: 站點附近可用嘅 CTB／聯營附近路線。
    private func ctbDashboardRoutes(near stopInfo: StopInfo, jointOnly: Bool = false) async -> [NearbyRouteModel] {
        guard let stopLocation = stopInfo.clLocation else {
            let routes = (try? await ctbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            return jointOnly ? routes.filter { $0.co == "KMB+CTB" } : routes
        }
        let routes = (try? await ctbETAProvider.fetchNearbyRoutes(near: stopLocation)) ?? []
        return jointOnly ? routes.filter { $0.co == "KMB+CTB" } : routes
    }

    /// 套用短期 ETA 快取，並喺主執行緒儲存最新 ETA 結果。
    /// - Parameters:
    ///   - routes: Providers 返回嘅路線模型。
    ///   - stopId: 用於快取 key 嘅站點身份。
    ///   - forceRefresh: 是否略過快取值。
    /// - Returns: 可用時已填入快取 ETA 嘅路線。
    private func cachedRoutes(_ routes: [NearbyRouteModel], stopId: String, forceRefresh: Bool = false) async -> [NearbyRouteModel] {
        await MainActor.run {
            routes.map { route in
                let key = dashboardETAKey(route: route, stopId: stopId)
                if !route.etas.isEmpty {
                    dashboardETAByKey[key] = (Date(), route.etas)
                    return route
                }
                guard !forceRefresh,
                      let cachedEntry = dashboardETAByKey[key],
                      Date().timeIntervalSince(cachedEntry.updatedAt) <= dashboardETACacheLifetime else {
                    return route
                }
                return routeWithETAs(route, etas: cachedEntry.etas)
            }
        }
    }

    /// 建立一份附近路線副本，用新 ETA 值取代原有 ETA，同時保留路線 metadata。
    /// - Parameters:
    ///   - route: 來源附近路線模型。
    ///   - etas: 要附加到副本路線嘅 ETA 值。
    /// - Returns: 同 `route` 擁有相同身份同顯示欄位嘅路線模型。
    private func routeWithETAs(_ route: NearbyRouteModel, etas: [ETADisplayInfo]) -> NearbyRouteModel {
        NearbyRouteModel(
            co: route.co,
            route: route.route,
            directionCode: route.directionCode,
            destNameTc: route.destNameTc,
            displayStopName: route.displayStopName,
            displayStopId: route.displayStopId,
            etas: etas,
            detailDirectionCode: route.detailDirectionCode,
            operatorStopIds: route.operatorStopIds
        )
    }

    private var dashboardETACacheLifetime: TimeInterval { 30 }

    /// 建立附近首頁顯示 ETA 值所用嘅快取 key。
    /// - Parameters:
    ///   - route: ETA 值會被快取嘅路線。
    ///   - stopId: 用嚟區分同一路線喺唔同附近站點嘅站點身份 key。
    /// - Returns: 包含營辦商、路線、方向同站點身份嘅穩定字串 key。
    private func dashboardETAKey(route: NearbyRouteModel, stopId: String) -> String {
        "\(route.co)-\(route.route.uppercased())-\(route.directionCode)-\(stopId)"
    }

    /// 標準化站點顯示名稱，用於跨營辦商路線配對。
    /// - Parameter stopName: 原始站名，可能包含站柱編號或逗號分隔尾段。
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

    /// 將站點緯度同經度字串轉成 Core Location 物件。
    /// - Parameter stopInfo: 可能包含 `lat` 同 `long` 字串值嘅站點紀錄。
    /// - Returns: 兩個座標都可解析時返回 `CLLocation`，否則返回 `nil`。
    private func location(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    /// 篩選所有位於首頁搜尋半徑內嘅站點，並按距離排序。
    /// - Parameters:
    ///   - stops: 所有營辦商嘅完整靜態站點列表。
    ///   - userLocation: 作為距離起點嘅目前裝置位置。
    ///   - radius: 站點可被納入嘅最大距離，單位為米。
    /// - Returns: 由近至遠排序嘅附近站點模型。
    private func nearbyStopModels(from stops: [StopInfo], userLocation: CLLocation, radius: CLLocationDistance) -> [NearbyStopModel] {
        stops
            .compactMap { stop -> NearbyStopModel? in
                guard let stopLocation = stop.clLocation else { return nil }
                let distance = userLocation.distance(from: stopLocation)
                guard distance <= radius else { return nil }
                return NearbyStopModel(stopInfo: stop, distance: distance)
            }
            .sorted { $0.distance < $1.distance }
    }
}
/// 輸出啟動同附近 ETA 效能嘅精簡計時診斷。
/// - Parameters:
///   - step: 步驟名稱。
///   - startedAt: 開始時間。
///   - detail: log 行嘅可選脈絡。
/// - Returns: 無回傳值；會透過 console 輸出完成工作。
nonisolated private func logTiming(_ step: String, startedAt: Date, detail: String? = nil) {
    let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
    if let detail, !detail.isEmpty {
        print("[Performance] \(step): \(milliseconds)ms (\(detail))")
    } else {
        print("[Performance] \(step): \(milliseconds)ms")
    }
}
