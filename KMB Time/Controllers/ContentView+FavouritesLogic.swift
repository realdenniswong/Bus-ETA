import Foundation

extension ContentView {
    /// Refreshes ETA and nearest-stop status for every saved favourite route.
    func updateFavoriteETAs() async {
        guard let userLocation = locationManager.location else { return }
        
        let context = RouteStopLookupContext(userLocation: userLocation, stopInfoById: stopInfoDictionary)
        let favorites = favoritesManager.favoriteRoutes
        var statuses: [String: FavoriteStatusModel] = [:]
        
        for favorite in favorites {
            do {
                let direction = BusDirection(rawValue: favorite.direction) ?? .outbound
                let provider = providerForRoute(route: favorite.route, direction: direction)
                if let status = try await provider.fetchFavoriteStatus(for: favorite, context: context) {
                    statuses[favorite.id] = status
                }
            } catch {
                print("Failed to refresh favourite \(favorite.id): \(error)")
            }
        }
        
        await MainActor.run {
            self.favoriteStatus = statuses
        }
    }
}
