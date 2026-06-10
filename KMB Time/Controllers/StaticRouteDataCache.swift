/// 檔案用途：載入、快取同套用靜態路線及站點資料。
import Foundation

/// `StaticRouteDataSnapshot` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct StaticRouteDataSnapshot: Codable {
    let version: Int
    let updatedAt: Date
    let routes: [RouteSuggestion]
    let stops: [StopInfo]
}

/// `StaticRouteDataCache` 列出此功能範圍會用到嘅固定選項。
enum StaticRouteDataCache {
    private static let currentVersion = 1
    private static let fileName = "static-route-data-cache.json"
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - routes: 路線編號或路線模型。
    ///   - stops: 車站識別或車站資料。
    /// - Returns: 計算後嘅 `StaticRouteDataSnapshot`。
    static func makeSnapshot(routes: [RouteSuggestion], stops: [StopInfo]) -> StaticRouteDataSnapshot {
        StaticRouteDataSnapshot(
            version: currentVersion,
            updatedAt: Date(),
            routes: routes,
            stops: stops
        )
    }
    
    /// 載入需要嘅資料並更新本機狀態或快取。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    static func load() async -> StaticRouteDataSnapshot? {
        guard let fileURL = cacheFileURL(),
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(StaticRouteDataSnapshot.self, from: data),
              snapshot.version == currentVersion,
              !snapshot.routes.isEmpty,
              !snapshot.stops.isEmpty else {
            return nil
        }
        return snapshot
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - snapshot: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    static func save(_ snapshot: StaticRouteDataSnapshot) async {
        guard let fileURL = cacheFileURL() else { return }
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("Failed to save static route data cache: \(error)")
        }
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 找到時回傳對應資料；沒有時為 nil。
    private static func cacheFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KMB Time", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
