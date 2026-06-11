/// 檔案用途：更新收藏路線 ETA，並喺資料齊備後預熱收藏狀態。
import Foundation

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// 更新每條已收藏路線嘅 ETA、最近站點同距離狀態。
    ///
    /// 每條收藏會並行請求，完成後喺主執行緒一次過發布完整 `favoriteStatus` 字典。無位置、無收藏，或者已有更新進行緊時會提早結束。
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
    
    /// 收藏、位置同靜態站點資料準備好後，啟動第一次收藏 ETA 更新。
    ///
    /// 避免啟動後收藏首頁長時間空白；如果狀態資料已存在，仍然會略過重複更新。
    func warmFavoriteETAsIfPossible() {
        guard !favoritesManager.favoriteRoutes.isEmpty,
              favoriteStatus.isEmpty,
              locationManager.location != nil else { return }
        Task { await updateFavoriteETAs() }
    }
}
