/// 檔案用途：管理收藏路線嘅儲存、讀取同切換狀態。

import SwiftUI
import Combine

// The model for a saved route
/// `FavoriteRoute` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct FavoriteRoute: Identifiable, Codable {
    var id: String { "\(route)-\(direction)-\(company)" }
    let route: String
    let direction: String // "outbound" or "inbound"
    let destNameTc: String
    let company: String
    
    /// `CodingKeys` 列出此功能範圍會用到嘅固定選項。
    enum CodingKeys: String, CodingKey {
        case route
        case direction
        case destNameTc
        case company
    }
    
    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - destNameTc: 畫面顯示文字。
    ///   - company: 巴士公司代碼。
    /// - Returns: 無回傳值；完成物件初始化。
    init(route: String, direction: String, destNameTc: String, company: String = BusOperator.kmb.rawValue) {
        self.route = route
        self.direction = direction
        self.destNameTc = destNameTc
        self.company = company
    }
    
    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - from: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；完成物件初始化。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        route = try container.decode(String.self, forKey: .route)
        direction = try container.decode(String.self, forKey: .direction)
        destNameTc = try container.decode(String.self, forKey: .destNameTc)
        company = try container.decodeIfPresent(String.self, forKey: .company) ?? BusOperator.kmb.rawValue
    }
}

// The manager that talks to UserDefaults
/// `FavoritesManager` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
class FavoritesManager: ObservableObject {
    @Published var favoriteRoutes: [FavoriteRoute] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    /// 建立物件並準備需要嘅初始狀態。
    /// - Parameters:
    ///   - userDefaults: 此函式需要嘅輸入資料。
    ///   - storageKey: 用嚟查找、快取或請求資料嘅識別值。
    /// - Returns: 無回傳值；完成物件初始化。
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
    
    // Add if it doesn't exist, remove if it does
    /// 切換指定項目嘅狀態。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - destName: 畫面顯示文字。
    ///   - company: 巴士公司代碼。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    func toggleFavorite(route: String, direction: String, destName: String, company: String = BusOperator.kmb.rawValue) {
        let favId = "\(route)-\(direction)-\(company)"
        if let index = favoriteRoutes.firstIndex(where: { $0.id == favId }) {
            favoriteRoutes.remove(at: index)
        } else {
            favoriteRoutes.append(FavoriteRoute(route: route, direction: direction, destNameTc: destName, company: company))
        }
    }
    
    // Check if a route is currently favorited
    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - company: 巴士公司代碼。
    /// - Returns: 條件是否成立。
    func isFavorite(route: String, direction: String, company: String? = nil) -> Bool {
        if let company {
            return favoriteRoutes.contains(where: { $0.id == "\(route)-\(direction)-\(company)" })
        }
        return favoriteRoutes.contains(where: { $0.route == route && $0.direction == direction })
    }
}
