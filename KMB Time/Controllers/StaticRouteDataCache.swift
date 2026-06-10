import Foundation

struct StaticRouteDataSnapshot: Codable {
    let version: Int
    let updatedAt: Date
    let routes: [RouteSuggestion]
    let stops: [StopInfo]
}

enum StaticRouteDataCache {
    private static let currentVersion = 1
    private static let fileName = "static-route-data-cache.json"
    
    static func makeSnapshot(routes: [RouteSuggestion], stops: [StopInfo]) -> StaticRouteDataSnapshot {
        StaticRouteDataSnapshot(
            version: currentVersion,
            updatedAt: Date(),
            routes: routes,
            stops: stops
        )
    }
    
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
    
    private static func cacheFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KMB Time", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
