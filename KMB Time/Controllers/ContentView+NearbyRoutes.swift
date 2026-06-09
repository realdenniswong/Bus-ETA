import CoreLocation

extension ContentView {
    /// Rebuilds the nearby dashboard from the user's current location.
    func updateNearbyStops(userLocation: CLLocation) async {
        guard !allStops.isEmpty else { return }
        
        let shouldStartUpdate = await MainActor.run {
            guard !isUpdatingNearby else { return false }
            isUpdatingNearby = true
            isSearchingNearby = true
            return true
        }
        guard shouldStartUpdate else { return }
        
        let nearestStops = nearestStopModels(from: allStops, userLocation: userLocation, limit: 10)
        let nearbyCTBStops = await nearestCTBStopModels(userLocation: userLocation, excluding: nearestStops)
        let dashboardStops = Array((nearestStops + nearbyCTBStops)
            .sorted { $0.distance < $1.distance }
            .prefix(12))
        let nearbyStopsWithRoutes: [NearbyStopModel]
        if dashboardViewMode == .allBuses {
            nearbyStopsWithRoutes = await nearbyStopsForAllBusesMode(dashboardStops)
        } else {
            nearbyStopsWithRoutes = await nearbyStopsForExpandedGroups(dashboardStops)
        }
        
        await MainActor.run {
            self.nearbyStops = nearbyStopsWithRoutes
            self.isSearchingNearby = false
            self.isUpdatingNearby = false
        }
    }
    
    /// Refreshes ETA rows for the stops already displayed on the nearby dashboard.
    func refreshNearbyETAs() async {
        guard !nearbyStops.isEmpty else { return }
        await MainActor.run { isSearchingNearby = true }
        
        let refreshedStops: [NearbyStopModel]
        if dashboardViewMode == .allBuses {
            refreshedStops = await nearbyStopsForAllBusesMode(nearbyStops)
        } else {
            refreshedStops = await nearbyStopsForExpandedGroups(nearbyStops, forceRefresh: true)
        }
        
        await MainActor.run {
            self.nearbyStops = refreshedStops
            self.isSearchingNearby = false
        }
    }
    
    private func nearbyStopsForAllBusesMode(_ stops: [NearbyStopModel]) async -> [NearbyStopModel] {
        var fetchedStops: [NearbyStopModel] = []
        var uniqueRouteKeys = Set<String>()
        let maxUniqueRoutes = 24
        
        for stop in stops.sorted(by: { $0.distance < $1.distance }) {
            var stopWithRoutes = stop
            stopWithRoutes.routes = await fetchRoutesForNearbyStop(stop.stopInfo)
            fetchedStops.append(stopWithRoutes)
            
            for route in stopWithRoutes.routes {
                uniqueRouteKeys.insert(dashboardRouteKey(route: route))
            }
            if uniqueRouteKeys.count >= maxUniqueRoutes {
                break
            }
        }
        
        let fetchedStopIds = Set(fetchedStops.map { $0.stopInfo.stop })
        let unfetchedStops = stops.filter { !fetchedStopIds.contains($0.stopInfo.stop) }
        return (fetchedStops + unfetchedStops.map { stop in
            var stopWithoutRoutes = stop
            stopWithoutRoutes.routes = []
            return stopWithoutRoutes
        })
        .sorted { $0.distance < $1.distance }
    }
    
    private func nearbyStopsForExpandedGroups(_ stops: [NearbyStopModel], forceRefresh: Bool = false) async -> [NearbyStopModel] {
        var fetchedStops: [NearbyStopModel] = []
        for stop in stops.sorted(by: { $0.distance < $1.distance }) {
            var stopWithRoutes = stop
            if shouldFetchRoutesForGroupedStop(stop.stopInfo) {
                stopWithRoutes.routes = await fetchRoutesForNearbyStop(stop.stopInfo, forceRefresh: forceRefresh)
            } else {
                stopWithRoutes.routes = cachedRoutes(from: stop.routes)
            }
            fetchedStops.append(stopWithRoutes)
        }
        return fetchedStops
    }
    
    private func nearestCTBStopModels(userLocation: CLLocation, excluding existingStops: [NearbyStopModel]) async -> [NearbyStopModel] {
        let existingStopIds = Set(existingStops.map { $0.stopInfo.stop })
        let ctbStops = (try? await ctbETAProvider.nearbyStops(near: userLocation, limit: 8)) ?? []
        return ctbStops.compactMap { stopInfo in
            guard !existingStopIds.contains(stopInfo.stop),
                  let stopLocation = location(from: stopInfo) else { return nil }
            return NearbyStopModel(stopInfo: stopInfo, distance: userLocation.distance(from: stopLocation))
        }
    }
    
    /// Fetches provider route cards for one displayed nearby stop.
    func fetchRoutesForNearbyStop(_ stopInfo: StopInfo, forceRefresh: Bool = false) async -> [NearbyRouteModel] {
        let stopLocation = location(from: stopInfo)
        async let kmbRoutes = (try? kmbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
        async let ctbRoutes: [NearbyRouteModel] = {
            if let stopLocation {
                return (try? await ctbETAProvider.fetchNearbyRoutes(near: stopLocation)) ?? []
            }
            return (try? await ctbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
        }()
        let routes = dashboardRoutes(kmbRoutes: await kmbRoutes, ctbRoutes: await ctbRoutes)
        return routes
            .map { cachedRoute($0, stopId: stopInfo.stop, forceRefresh: forceRefresh) }
            .sorted {
                if $0.route == $1.route { return $0.directionCode < $1.directionCode }
                return $0.route.localizedStandardCompare($1.route) == .orderedAscending
            }
    }
    
    private func dashboardRoutes(kmbRoutes: [NearbyRouteModel], ctbRoutes: [NearbyRouteModel]) -> [NearbyRouteModel] {
        let relabeledKMBRoutes = kmbRoutes.map { route in
            let direction = BusDirection(routeCode: route.directionCode)
            guard ctbETAProvider.isJointRoute(route: route.route, direction: direction) else {
                return route
            }
            return jointRouteUsingKMBETA(route)
        }
        let ctbOnlyRoutes = ctbRoutes.filter { $0.co != "KMB+CTB" }
        return relabeledKMBRoutes + ctbOnlyRoutes
    }
    
    private func jointRouteUsingKMBETA(_ route: NearbyRouteModel) -> NearbyRouteModel {
        NearbyRouteModel(
            co: "KMB+CTB",
            route: route.route,
            directionCode: route.directionCode,
            destNameTc: route.destNameTc,
            displayStopName: route.displayStopName,
            displayStopId: route.displayStopId,
            etas: route.etas,
            detailDirectionCode: route.detailDirectionCode ?? route.directionCode
        )
    }
    
    private func mergeJointNearbyRoutes(_ routes: [NearbyRouteModel]) -> [NearbyRouteModel] {
        var unmatchedRoutes: [NearbyRouteModel] = []
        let kmbRoutes = routes.filter { $0.co == BusOperator.kmb.rawValue }
        let jointRoutes = routes.filter { $0.co == "KMB+CTB" }
        var mergedJointIds = Set<UUID>()
        var mergedKMBIds = Set<UUID>()
        
        for jointRoute in jointRoutes {
            guard let kmbRoute = kmbRoutes.first(where: { candidate in
                !mergedKMBIds.contains(candidate.id) &&
                candidate.route.uppercased() == jointRoute.route.uppercased() &&
                normalizedStationName(candidate.destNameTc) == normalizedStationName(jointRoute.destNameTc)
            }) ?? kmbRoutes.first(where: { candidate in
                !mergedKMBIds.contains(candidate.id) &&
                candidate.route.uppercased() == jointRoute.route.uppercased() &&
                candidate.directionCode == jointRoute.directionCode
            }) else {
                unmatchedRoutes.append(routeWithETAs(jointRoute, etas: []))
                continue
            }
            
            unmatchedRoutes.append(mergedJointRoute(jointRoute: jointRoute, kmbRoute: kmbRoute))
            mergedJointIds.insert(jointRoute.id)
            mergedKMBIds.insert(kmbRoute.id)
        }
        
        unmatchedRoutes.append(contentsOf: routes.filter { route in
            !mergedJointIds.contains(route.id) && !mergedKMBIds.contains(route.id) && route.co != "KMB+CTB"
        })
        
        return unmatchedRoutes
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
    
    private func shouldFetchRoutesForGroupedStop(_ stopInfo: StopInfo) -> Bool {
        switch dashboardViewMode {
        case .byStation:
            return expandedStopIds.contains(stopInfo.stop)
        case .byStationName:
            return expandedStopIds.contains(normalizedStationName(stopInfo.name_tc))
        case .allBuses:
            return true
        }
    }
    
    private func cachedRoutes(from routes: [NearbyRouteModel]) -> [NearbyRouteModel] {
        routes.map { cachedRoute($0, stopId: routeCacheStopId(for: $0)) }
    }
    
    private func cachedRoute(_ route: NearbyRouteModel, stopId: String, forceRefresh: Bool = false) -> NearbyRouteModel {
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
    
    private func routeWithETAs(_ route: NearbyRouteModel, etas: [ETADisplayInfo]) -> NearbyRouteModel {
        NearbyRouteModel(
            co: route.co,
            route: route.route,
            directionCode: route.directionCode,
            destNameTc: route.destNameTc,
            displayStopName: route.displayStopName,
            displayStopId: route.displayStopId,
            etas: etas,
            detailDirectionCode: route.detailDirectionCode
        )
    }
    
    private var dashboardETACacheLifetime: TimeInterval { 30 }
    
    private func dashboardETAKey(route: NearbyRouteModel, stopId: String) -> String {
        "\(route.co)-\(route.route.uppercased())-\(route.directionCode)-\(stopId)"
    }
    
    private func dashboardRouteKey(route: NearbyRouteModel) -> String {
        "\(route.co)-\(route.route.uppercased())-\(route.directionCode)"
    }
    
    private func routeCacheStopId(for route: NearbyRouteModel) -> String {
        nearbyStops.first { stop in
            stop.routes.contains { $0.id == route.id }
        }?.stopInfo.stop ?? ""
    }
    
    private func normalizedStationName(_ stopName: String) -> String {
        stopName.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
    }
    
    private func location(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
    
    private func nearestStopModels(from stops: [StopInfo], userLocation: CLLocation, limit: Int) -> [NearbyStopModel] {
        stops
            .compactMap { stop -> NearbyStopModel? in
                guard let stopLocation = stop.clLocation else { return nil }
                return NearbyStopModel(stopInfo: stop, distance: userLocation.distance(from: stopLocation))
            }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { $0 }
    }
}
