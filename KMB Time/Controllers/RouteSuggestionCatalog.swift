/// 檔案用途：建立可搜尋路線建議索引，處理公司優先次序同合併。
import Foundation

/// `RouteSuggestionCatalog` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct RouteSuggestionCatalog {
    let suggestions: [RouteSuggestion]
    var ctbCompanyCodeProvider: ((String, BusDirection) -> String?)?
    
    /// 按照輸入條件搜尋路線並準備顯示結果。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    ///   - limit: 最多回傳嘅項目數量。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func searchSuggestions(for searchText: String, limit: Int = 30) -> [RouteSuggestion] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.uppercased()
        return Array(suggestions.filter { $0.route.uppercased().hasPrefix(query) }.prefix(limit))
    }
    
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - for: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    func validNextKeys(for searchText: String) -> Set<String>? {
        guard !suggestions.isEmpty else { return nil }
        
        let query = searchText.uppercased()
        if query.isEmpty {
            return Set(suggestions.compactMap { $0.route.first.map(String.init) })
        }
        
        var nextKeys = Set<String>()
        for suggestion in suggestions {
            let route = suggestion.route.uppercased()
            if route.hasPrefix(query) && route.count > query.count {
                let index = route.index(route.startIndex, offsetBy: query.count)
                nextKeys.insert(String(route[index]))
            }
        }
        return nextKeys
    }
    
    /// 整理或查找巴士公司顯示資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - preferredCompany: 巴士公司代碼。
    /// - Returns: 格式化或查找後嘅文字。
    func resolvedCompany(route: String, direction: BusDirection, preferredCompany: String) -> String {
        if hasCompany(route: route, direction: direction, company: preferredCompany) {
            return preferredCompany
        }
        return companyCode(route: route, direction: direction) ?? BusOperator.kmb.rawValue
    }
    
    /// 整理或查找巴士公司顯示資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 格式化或查找後嘅文字。
    func companyCode(route: String, direction: BusDirection) -> String? {
        let matches = routeSuggestions(route: route, direction: direction)
        if matches.count == 1 {
            return matches.first?.co
        }
        if let jointSuggestion = matches.first(where: { $0.co == "KMB+CTB" }) {
            return jointSuggestion.co
        }
        return ctbCompanyCodeProvider?(route, direction)
    }
    
    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    ///   - company: 巴士公司代碼。
    /// - Returns: 條件是否成立。
    func hasCompany(route: String, direction: BusDirection, company: String) -> Bool {
        routeSuggestions(route: route, direction: direction).contains { $0.co == company }
    }
    
    /// 整理或查找路線相關資料。
    /// - Parameters:
    ///   - route: 路線編號或路線模型。
    ///   - direction: 巴士方向資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    func routeSuggestions(route: String, direction: BusDirection) -> [RouteSuggestion] {
        let normalizedRoute = route.uppercased()
        let bound = direction.routeCode
        return suggestions.filter { $0.route == normalizedRoute && $0.bound == bound }
    }
    
    /// 合併多個資料來源並回傳統一結果。
    /// - Parameters:
    ///   - kmb: 此函式需要嘅輸入資料。
    ///   - ctb: 此函式需要嘅輸入資料。
    /// - Returns: 符合條件並已整理嘅資料列表。
    static func merged(kmb: [RouteSuggestion], ctb: [RouteSuggestion]) -> [RouteSuggestion] {
        var suggestionsByRouteDirectionCompany: [String: RouteSuggestion] = [:]
        
        for suggestion in kmb {
            suggestionsByRouteDirectionCompany[routeSuggestionKey(suggestion)] = suggestion
        }
        
        for suggestion in ctb {
            if suggestion.co == "KMB+CTB" {
                suggestionsByRouteDirectionCompany.removeValue(forKey: "\(suggestion.route)-\(suggestion.bound)-\(BusOperator.kmb.rawValue)")
            }
            suggestionsByRouteDirectionCompany[routeSuggestionKey(suggestion)] = suggestion
        }
        
        return suggestionsByRouteDirectionCompany.values.sorted {
            if $0.route == $1.route {
                if $0.bound == $1.bound {
                    return companySortRank($0.co) < companySortRank($1.co)
                }
                return $0.bound > $1.bound
            }
            return $0.route.localizedStandardCompare($1.route) == .orderedAscending
        }
    }
    
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - suggestion: 此函式需要嘅輸入資料。
    /// - Returns: 格式化或查找後嘅文字。
    private static func routeSuggestionKey(_ suggestion: RouteSuggestion) -> String {
        "\(suggestion.route)-\(suggestion.bound)-\(suggestion.co)"
    }
    
    /// 按畫面需要排序並回傳結果。
    /// - Parameters:
    ///   - company: 巴士公司代碼。
    /// - Returns: 計算後嘅 `Int`。
    private static func companySortRank(_ company: String) -> Int {
        switch company {
        case "KMB+CTB":
            return 0
        case BusOperator.kmb.rawValue:
            return 1
        case BusOperator.ctb.rawValue:
            return 2
        default:
            return 3
        }
    }
}
