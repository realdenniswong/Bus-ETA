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
    
    /// Loads route suggestions from KMB plus the bundled CTB route list.
    func loadAllRoutes() async {
        do {
            async let kmbSuggestions = kmbETAProvider.fetchRouteSuggestions()
            async let ctbSuggestions = ctbETAProvider.fetchRouteSuggestions()
            let routeSuggestions = try await mergedRouteSuggestions(kmb: kmbSuggestions, ctb: ctbSuggestions)
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
            async let kmbStops = kmbETAProvider.fetchStops()
            async let ctbStops = ctbETAProvider.fetchStops()
            let stops = try await kmbStops + ctbStops
            let stopNamesById = Dictionary(stops.map { ($0.stop, $0.name_tc) }, uniquingKeysWith: { first, _ in first })
            let identityStopInfo = stops.map { ($0.identityKey, $0) }
            let plainStopInfo = stops.map { ($0.stop, $0) }
            let stopInfoById = Dictionary(identityStopInfo + plainStopInfo, uniquingKeysWith: { first, _ in first })
            
            await MainActor.run {
                self.allStops = stops
                self.stopDictionary = stopNamesById
                self.stopInfoDictionary = stopInfoById
            }
            
            if let userLocation = locationManager.location {
                await updateNearbyStops(userLocation: userLocation)
                warmFavoriteETAsIfPossible()
            }
        } catch {
            print("Failed to load stops: \(error)")
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
