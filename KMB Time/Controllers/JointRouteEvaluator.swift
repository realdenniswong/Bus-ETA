//
//  JointRouteEvaluator.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/8/26.
//

import SwiftUI

// 💡 全域通用：100% 數據導向聯營線動態分析大腦
struct JointRouteEvaluator {
    // 🌟 記憶體快取：儲存所有已經被證實是聯營線的號碼 (例如: ["102", "112", "948"])
    static var jointRouteCache: Set<String> = []
    
    /// 💡 新增：在 loadAllRoutes 完結時呼叫一次，提前把全港聯營線算好放進記憶體
    static func precomputeJointRoutes(allRoutes: [RouteSuggestion]) {
        let allRouteNamesKMB = Set(allRoutes.filter { $0.co == "KMB" }.map { $0.route.uppercased() })
        let allRouteNamesCTB = Set(allRoutes.filter { $0.co == "CTB" }.map { $0.route.uppercased() })
        
        // 取兩間公司的交集，瞬間找出所有聯營號碼
        self.jointRouteCache = allRouteNamesKMB.intersection(allRouteNamesCTB)
        print("⚡️ [Cache] 聯營線預處理完成！共找到 \(jointRouteCache.count) 條聯營路線。")
    }
    
    /// 🌟 極速檢查：現在只需要 0.00001 秒，直接去 Set 裡面查有沒有這個號碼！
    static func checkIsJoint(route: String, allRoutes: [RouteSuggestion]) -> Bool {
        let upperRoute = route.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return jointRouteCache.contains(upperRoute)
    }
    
    // 🌟 喺度修正顏色：聯營=藍色，九巴=紅色，城巴=黃色
    static func fetchThemeColor(route: String, originalCo: String, allRoutes: [RouteSuggestion]) -> Color {
        if checkIsJoint(route: route, allRoutes: allRoutes) {
            return Color.blue // 🔵 聯營線轉為藍色
        }
        // 城巴顯示黃色，九巴顯示原本嘅紅色
        return originalCo == "CTB" ? Color.orange : Color(red: 0.65, green: 0.08, blue: 0.12)
    }
}
