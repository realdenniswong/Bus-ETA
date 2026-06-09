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
        let dashboardStops = (nearestStops + nearbyCTBStops)
            .sorted { $0.distance < $1.distance }
            .prefix(12)
        let nearbyStopsWithRoutes = await nearbyStopsWithFetchedRoutes(Array(dashboardStops))
        
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
        
        let refreshedStops = await nearbyStopsWithFetchedRoutes(nearbyStops)
        
        await MainActor.run {
            self.nearbyStops = refreshedStops
            self.isSearchingNearby = false
        }
    }
    
    private func nearbyStopsWithFetchedRoutes(_ stops: [NearbyStopModel]) async -> [NearbyStopModel] {
        await withTaskGroup(of: NearbyStopModel.self) { group in
            for stop in stops {
                group.addTask {
                    var stopWithRoutes = stop
                    stopWithRoutes.routes = await fetchRoutesForNearbyStop(stop.stopInfo)
                    return stopWithRoutes
                }
            }
            
            var fetchedStops: [NearbyStopModel] = []
            for await stop in group {
                fetchedStops.append(stop)
            }
            return fetchedStops.sorted { $0.distance < $1.distance }
        }
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
    func fetchRoutesForNearbyStop(_ stopInfo: StopInfo) async -> [NearbyRouteModel] {
        let stopLocation = location(from: stopInfo)
        async let kmbRoutes = (try? kmbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
        async let ctbRoutes: [NearbyRouteModel] = {
            if let stopLocation {
                return (try? await ctbETAProvider.fetchNearbyRoutes(near: stopLocation)) ?? []
            }
            return (try? await ctbETAProvider.fetchNearbyRoutes(forStopId: stopInfo.stop)) ?? []
        }()
        let routes = await kmbRoutes + ctbRoutes
        return routes.sorted {
            if $0.route == $1.route { return $0.directionCode < $1.directionCode }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
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
