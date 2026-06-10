/// 檔案用途：根據路線同公司產生畫面配色。

import SwiftUI

/// `KMBRouteTheme` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct KMBRouteTheme {
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - company: 巴士公司代碼。
    ///   - allRoutes: 路線編號或路線模型。
    /// - Returns: 畫面應使用嘅顏色。
    static func backgroundColor(route: String, company: String, allRoutes: [RouteSuggestion]) -> Color {
        if company == BusOperator.ctb.rawValue {
            return Color(red: 0xF7 / 255, green: 0xDE / 255, blue: 0x06 / 255)
        }
        if company == "KMB+CTB" {
            return Color(red: 0.12, green: 0.32, blue: 0.58)
        }
        return Color(red: 0.65, green: 0.08, blue: 0.12)
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - company: 巴士公司代碼。
    ///   - allRoutes: 路線編號或路線模型。
    /// - Returns: 畫面應使用嘅顏色。
    static func foregroundColor(route: String, company: String, allRoutes: [RouteSuggestion]) -> Color {
        if company == BusOperator.ctb.rawValue {
            return Color(red: 0x01 / 255, green: 0x5D / 255, blue: 0xA6 / 255)
        }
        return .white
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - company: 巴士公司代碼。
    ///   - allRoutes: 路線編號或路線模型。
    /// - Returns: 畫面應使用嘅顏色。
    static func color(route: String, company: String, allRoutes: [RouteSuggestion]) -> Color {
        backgroundColor(route: route, company: company, allRoutes: allRoutes)
    }
}
