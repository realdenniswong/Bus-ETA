/// 檔案用途：管理收藏路線嘅儲存、讀取同切換狀態。

import SwiftUI
import Combine

/// 使用者標記為收藏嘅路線儲存表示。
struct FavoriteRoute: Identifiable, Codable {
    var id: String { "\(route)-\(direction)-\(company)" }
    let route: String
    let direction: String // "outbound" 或 "inbound"
    let destNameTc: String
    let company: String
    
    /// `CodingKeys` 列出此功能範圍會用到嘅固定選項。
    enum CodingKeys: String, CodingKey {
        case route
        case direction
        case destNameTc
        case company
    }
    
    /// 建立收藏路線紀錄。
    /// - Parameters:
    ///   - route: 使用者儲存嘅路線號碼。
    ///   - direction: 方向原始值，通常係 `outbound` 或 `inbound`。
    ///   - destNameTc: 收藏列表顯示嘅中文目的地名稱。
    ///   - company: 營辦商代碼；舊呼叫位置預設為 KMB。
    init(route: String, direction: String, destNameTc: String, company: String = BusOperator.kmb.rawValue) {
        self.route = route
        self.direction = direction
        self.destNameTc = destNameTc
        self.company = company
    }
    
    /// 解碼已儲存收藏，並為支援營辦商之前建立嘅紀錄補上 KMB 公司代碼。
    /// - Parameter decoder: 讀取持久化收藏 JSON 嘅 decoder。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        route = try container.decode(String.self, forKey: .route)
        direction = try container.decode(String.self, forKey: .direction)
        destNameTc = try container.decode(String.self, forKey: .destNameTc)
        company = try container.decodeIfPresent(String.self, forKey: .company) ?? BusOperator.kmb.rawValue
    }
}

/// 將收藏路線持久化到 `UserDefaults` 嘅可觀察儲存物件。
class FavoritesManager: ObservableObject {
    @Published var favoriteRoutes: [FavoriteRoute] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    /// 載入已儲存收藏，並開始觀察之後變更以作持久化。
    /// - Parameters:
    ///   - userDefaults: 用於讀寫收藏嘅儲存後端。
    ///   - storageKey: 儲存已編碼 `[FavoriteRoute]` payload 嘅 key。
    init(userDefaults: UserDefaults = .standard, storageKey: String = "saved_kmb_favorites") {
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([FavoriteRoute].self, from: data) {
            self.favoriteRoutes = decoded
        }
        
        $favoriteRoutes
            .dropFirst()
            .sink { [userDefaults, storageKey] newRoutes in
                if let encoded = try? JSONEncoder().encode(newRoutes) {
                    userDefaults.set(encoded, forKey: storageKey)
                }
            }
            .store(in: &cancellables)
    }
    
    /// 路線未收藏時加入收藏；已有配對收藏時移除。
    /// - Parameters:
    ///   - route: 要切換收藏狀態嘅路線號碼。
    ///   - direction: 收藏身份包含嘅方向原始值。
    ///   - destName: 為顯示而儲存嘅中文目的地名稱。
    ///   - company: 收藏身份包含嘅營辦商代碼。
    func toggleFavorite(route: String, direction: String, destName: String, company: String = BusOperator.kmb.rawValue) {
        let favId = "\(route)-\(direction)-\(company)"
        if let index = favoriteRoutes.firstIndex(where: { $0.id == favId }) {
            favoriteRoutes.remove(at: index)
        } else {
            favoriteRoutes.append(FavoriteRoute(route: route, direction: direction, destNameTc: destName, company: company))
        }
    }
    
    /// 檢查配對路線同方向是否已儲存。
    /// - Parameters:
    ///   - route: 要檢查嘅路線號碼。
    ///   - direction: 要檢查嘅方向原始值。
    ///   - company: 可選營辦商代碼；省略時會配對不分公司嘅舊收藏。
    /// - Returns: 存在配對收藏時返回 `true`。
    func isFavorite(route: String, direction: String, company: String? = nil) -> Bool {
        if let company {
            return favoriteRoutes.contains(where: { $0.id == "\(route)-\(direction)-\(company)" })
        }
        return favoriteRoutes.contains(where: { $0.route == route && $0.direction == direction })
    }
}
