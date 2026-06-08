//
//  FavouritesManager.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/5/26.
//

import SwiftUI
import Combine

// The model for a saved route
struct FavoriteRoute: Identifiable, Codable {
    var id: String { "\(route)-\(direction)-\(company)" }
    let route: String
    let direction: String // "outbound" or "inbound"
    let destNameTc: String
    let company: String
    
    enum CodingKeys: String, CodingKey {
        case route
        case direction
        case destNameTc
        case company
    }
    
    init(route: String, direction: String, destNameTc: String, company: String = BusOperator.kmb.rawValue) {
        self.route = route
        self.direction = direction
        self.destNameTc = destNameTc
        self.company = company
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        route = try container.decode(String.self, forKey: .route)
        direction = try container.decode(String.self, forKey: .direction)
        destNameTc = try container.decode(String.self, forKey: .destNameTc)
        company = try container.decodeIfPresent(String.self, forKey: .company) ?? BusOperator.kmb.rawValue
    }
}

// The manager that talks to UserDefaults
class FavoritesManager: ObservableObject {
    @Published var favoriteRoutes: [FavoriteRoute] = []
    
    // We use this to store our background saving task
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // 1. Load saved routes when the app starts
        if let data = UserDefaults.standard.data(forKey: "saved_kmb_favorites"),
           let decoded = try? JSONDecoder().decode([FavoriteRoute].self, from: data) {
            self.favoriteRoutes = decoded
        }
        
        // 2. Automatically save whenever the list changes (Fixes the @Published didSet compiler bug)
        $favoriteRoutes
            .dropFirst() // Don't save on the initial load
            .sink { newRoutes in
                if let encoded = try? JSONEncoder().encode(newRoutes) {
                    UserDefaults.standard.set(encoded, forKey: "saved_kmb_favorites")
                }
            }
            .store(in: &cancellables)
    }
    
    // Add if it doesn't exist, remove if it does
    func toggleFavorite(route: String, direction: String, destName: String, company: String = BusOperator.kmb.rawValue) {
        let favId = "\(route)-\(direction)-\(company)"
        if let index = favoriteRoutes.firstIndex(where: { $0.id == favId }) {
            favoriteRoutes.remove(at: index)
        } else {
            favoriteRoutes.append(FavoriteRoute(route: route, direction: direction, destNameTc: destName, company: company))
        }
    }
    
    // Check if a route is currently favorited
    func isFavorite(route: String, direction: String, company: String? = nil) -> Bool {
        if let company {
            return favoriteRoutes.contains(where: { $0.id == "\(route)-\(direction)-\(company)" })
        }
        return favoriteRoutes.contains(where: { $0.route == route && $0.direction == direction })
    }
}
