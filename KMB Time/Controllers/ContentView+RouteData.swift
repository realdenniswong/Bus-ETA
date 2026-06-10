import Foundation

extension ContentView {
    var kmbETAProvider: KMBETAProvider {
        KMBETAProvider.shared
    }
    
    var ctbETAProvider: CTBETAProvider {
        CTBETAProvider.shared
    }
    
    var jointRouteETAProvider: JointRouteETAProvider {
        JointRouteETAProvider.shared
    }
    
    /// Loads cached static route data immediately, then refreshes it from providers.
    func loadStaticRouteData() async {
        let loadedCachedData = await loadCachedStaticRouteData()
        
        if loadedCachedData {
            Task { await refreshStaticRouteData() }
        } else {
            await refreshStaticRouteData()
        }
    }
    
    /// Loads route suggestions from KMB plus the bundled CTB route list.
    func loadAllRoutes() async {
        do {
            let routeSuggestions = try await fetchAllRouteSuggestions()
            await MainActor.run {
                self.allRoutes = routeSuggestions
            }
        } catch {
            print("Failed to load route suggestions: \(error)")
        }
    }
    
    /// Loads stops from KMB and CTB and builds lookup dictionaries for the UI.
    func loadAllStops() async {
        do {
            let stops = try await fetchAllStops()
            await applyStops(stops)
            await updateNearbyStopsAfterStaticDataLoad()
        } catch {
            print("Failed to load stops: \(error)")
        }
    }
    
    private func loadCachedStaticRouteData() async -> Bool {
        guard let snapshot = await StaticRouteDataCache.load() else { return false }
        await applyStaticRouteData(routes: snapshot.routes, stops: snapshot.stops)
        await updateNearbyStopsAfterStaticDataLoad()
        return true
    }
    
    private func refreshStaticRouteData() async {
        do {
            async let routesRequest = fetchAllRouteSuggestions()
            async let stopsRequest = fetchAllStops()
            let (routes, stops) = try await (routesRequest, stopsRequest)
            
            await applyStaticRouteData(routes: routes, stops: stops)
            await StaticRouteDataCache.save(StaticRouteDataCache.makeSnapshot(routes: routes, stops: stops))
            await updateNearbyStopsAfterStaticDataLoad()
        } catch {
            print("Failed to refresh static route data: \(error)")
        }
    }
    
    private func fetchAllRouteSuggestions() async throws -> [RouteSuggestion] {
        async let kmbSuggestions = kmbETAProvider.fetchRouteSuggestions()
        async let ctbSuggestions = ctbETAProvider.fetchRouteSuggestions()
        return try await mergedRouteSuggestions(kmb: kmbSuggestions, ctb: ctbSuggestions)
    }
    
    private func fetchAllStops() async throws -> [StopInfo] {
        async let kmbStops = kmbETAProvider.fetchStops()
        async let ctbStops = ctbETAProvider.fetchStops()
        return try await kmbStops + ctbStops
    }
    
    private func applyStaticRouteData(routes: [RouteSuggestion], stops: [StopInfo]) async {
        await MainActor.run {
            self.allRoutes = routes
        }
        await applyStops(stops)
    }
    
    private func applyStops(_ stops: [StopInfo]) async {
        let stopNamesById = Dictionary(stops.map { ($0.stop, $0.name_tc) }, uniquingKeysWith: { first, _ in first })
        let identityStopInfo = stops.map { ($0.identityKey, $0) }
        let plainStopInfo = stops.map { ($0.stop, $0) }
        let stopInfoById = Dictionary(identityStopInfo + plainStopInfo, uniquingKeysWith: { first, _ in first })
        
        await MainActor.run {
            self.allStops = stops
            self.stopDictionary = stopNamesById
            self.stopInfoDictionary = stopInfoById
        }
    }
    
    private func updateNearbyStopsAfterStaticDataLoad() async {
        if let userLocation = locationManager.location {
            await updateNearbyStops(userLocation: userLocation)
            warmFavoriteETAsIfPossible()
        }
    }
    
    private func mergedRouteSuggestions(kmb: [RouteSuggestion], ctb: [RouteSuggestion]) -> [RouteSuggestion] {
        var suggestionsByRouteDirectionCompany: [String: RouteSuggestion] = [:]
        
        for suggestion in kmb {
            suggestionsByRouteDirectionCompany[routeSuggestionKey(suggestion)] = suggestion
        }
        
        for suggestion in ctb {
            if suggestion.co == "KMB+CTB" {
                suggestionsByRouteDirectionCompany.removeValue(forKey: "\(suggestion.route)-\(suggestion.bound)-\(BusOperator.kmb.rawValue)")
            }
            suggestionsByRouteDirectionCompany[routeSuggestionKey(suggestion)] = suggestion
        }
        
        return suggestionsByRouteDirectionCompany.values.sorted {
            if $0.route == $1.route {
                if $0.bound == $1.bound {
                    return companySortRank($0.co) < companySortRank($1.co)
                }
                return $0.bound > $1.bound
            }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }
    
    private func routeSuggestionKey(_ suggestion: RouteSuggestion) -> String {
        "\(suggestion.route)-\(suggestion.bound)-\(suggestion.co)"
    }
    
    private func companySortRank(_ company: String) -> Int {
        switch company {
        case "KMB+CTB":
            return 0
        case BusOperator.kmb.rawValue:
            return 1
        case BusOperator.ctb.rawValue:
            return 2
        default:
            return 3
        }
    }
}
