/// 檔案用途：更新收藏路線 ETA，並喺資料齊備後預熱收藏狀態。
import Foundation

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 更新相關狀態，令畫面或快取保持最新。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
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
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func warmFavoriteETAsIfPossible() {
        guard !favoritesManager.favoriteRoutes.isEmpty,
              favoriteStatus.isEmpty,
              locationManager.location != nil else { return }
        Task { await updateFavoriteETAs() }
    }
}
