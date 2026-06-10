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
        
        let dashboardStops = nearbyStopModels(from: allStops, userLocation: userLocation, radius: 300)
        let nearbyStopsWithRoutes = await nearbyStopsForAllBusesMode(dashboardStops)
        
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
        
        let refreshedStops = await nearbyStopsForAllBusesMode(nearbyStops)
        
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
            stopWithRoutes.hasFetchedRoutes = true
            fetchedStops.append(stopWithRoutes)
            
            for route in stopWithRoutes.routes {
                uniqueRouteKeys.insert(dashboardRouteKey(route: route))
            }
            if uniqueRouteKeys.count >= maxUniqueRoutes {
                break
            }
        }
        
        let fetchedStopIds = Set(fetchedStops.map { $0.stopInfo.identityKey })
        let unfetchedStops = stops.filter { !fetchedStopIds.contains($0.stopInfo.identityKey) }
        return (fetchedStops + unfetchedStops.map { stop in
            var stopWithoutRoutes = stop
            stopWithoutRoutes.routes = []
            return stopWithoutRoutes
        })
        .sorted { $0.distance < $1.distance }
    }
    
    /// Fetches provider route cards for one displayed nearby stop.
    func fetchRoutesForNearbyStop(_ stopInfo: StopInfo, forceRefresh: Bool = false) async -> [NearbyRouteModel] {
        let routes: [NearbyRouteModel]
        switch stopInfo.operatorCode {
        case .kmb:
            async let kmbRoutes = (try? kmbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            async let jointRoutes = (try? jointRouteETAProvider.fetchNearbyRoutes(for: stopInfo)) ?? []
            routes = dashboardRoutes(kmbRoutes: await kmbRoutes, ctbRoutes: [], jointRoutes: await jointRoutes)
        case .ctb:
            let ctbRoutes = (try? await ctbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            routes = dashboardRoutes(kmbRoutes: [], ctbRoutes: ctbRoutes, jointRoutes: [])
        case nil:
            async let kmbRoutes = (try? kmbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            async let jointRoutes = (try? jointRouteETAProvider.fetchNearbyRoutes(for: stopInfo)) ?? []
            async let ctbRoutes = (try? ctbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
            routes = dashboardRoutes(kmbRoutes: await kmbRoutes, ctbRoutes: await ctbRoutes, jointRoutes: await jointRoutes)
        }
        return routes
            .map { cachedRoute($0, stopId: stopInfo.identityKey, forceRefresh: forceRefresh) }
            .sorted {
                if $0.route == $1.route { return $0.directionCode < $1.directionCode }
                return $0.route.localizedStandardCompare($1.route) == .orderedAscending
            }
    }
    
    private func dashboardRoutes(kmbRoutes: [NearbyRouteModel], ctbRoutes: [NearbyRouteModel], jointRoutes: [NearbyRouteModel]) -> [NearbyRouteModel] {
        let kmbOnlyRoutes = kmbRoutes.filter { route in
            !ctbETAProvider.isJointRoute(route: route.route, direction: BusDirection(routeCode: route.directionCode))
        }
        let ctbOnlyRoutes = ctbRoutes.filter { $0.co != "KMB+CTB" }
        return kmbOnlyRoutes + jointRoutes + ctbOnlyRoutes
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
    
    private func location(from stopInfo: StopInfo) -> CLLocation? {
        guard let latitudeText = stopInfo.lat,
              let longitudeText = stopInfo.long,
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
    
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
