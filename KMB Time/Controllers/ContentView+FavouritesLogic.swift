import Foundation

extension ContentView {
    /// Refreshes ETA and nearest-stop status for every saved favourite route.
    func updateFavoriteETAs() async {
        guard let userLocation = locationManager.location,
              !favoritesManager.favoriteRoutes.isEmpty else { return }
        
        let shouldStartUpdate = await MainActor.run {
            guard !isUpdatingFavorites else { return false }
            isUpdatingFavorites = true
            return true
        }
        guard shouldStartUpdate else { return }
        defer {
            Task { @MainActor in
                isUpdatingFavorites = false
            }
        }
        
        let context = RouteStopLookupContext(userLocation: userLocation, stopInfoById: stopInfoDictionary)
        let requests = favoritesManager.favoriteRoutes.map { favorite in
            (id: favorite.id, favorite: favorite, provider: providerForCompany(favorite.company))
        }
        let statuses = await withTaskGroup(of: (String, FavoriteStatusModel)?.self) { group in
            for request in requests {
                group.addTask {
                    do {
                        if let status = try await request.provider.fetchFavoriteStatus(for: request.favorite, context: context) {
                            return (request.id, status)
                        }
                    } catch {
                        print("Failed to refresh favourite \(request.id): \(error)")
                    }
                    return nil
                }
            }
            
            var statuses: [String: FavoriteStatusModel] = [:]
            for await result in group {
                if let result {
                    statuses[result.0] = result.1
                }
            }
            return statuses
        }
        
        await MainActor.run {
            self.favoriteStatus = statuses
            self.isUpdatingFavorites = false
        }
    }
    
    func warmFavoriteETAsIfPossible() {
        guard !favoritesManager.favoriteRoutes.isEmpty,
              favoriteStatus.isEmpty,
              locationManager.location != nil else { return }
        Task { await updateFavoriteETAs() }
    }
}
