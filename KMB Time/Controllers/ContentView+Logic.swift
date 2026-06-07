import SwiftUI
import CoreLocation
import Combine
import UserNotifications
import ActivityKit

fileprivate class CSVRouteCache {
    static let shared = CSVRouteCache()
    var routesForStop: [String: [(route: String, bound: String, seq: Int)]] = [:]
}

fileprivate class CTBStopResolver {
    static let shared = CTBStopResolver()
    
    private var routeStopsCache: [String: [Int: String]] = [:]
    private var lock = NSLock()
    
    func getRealStopId(route: String, bound: String, seq: Int) async -> String? {
        let key = "\(route)-\(bound)"
        
        lock.lock()
        if let stops = routeStopsCache[key] {
            lock.unlock()
            return stops[seq]
        }
        lock.unlock()
        
        let dirStr = bound == "O" ? "outbound" : "inbound"
        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
        guard let url = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/route-stop/CTB/\(safeRoute)/\(dirStr)") else { return nil }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(CTBRouteStopResponse.self, from: data)
            
            var stopsDict: [Int: String] = [:]
            for stopItem in response.data {
                stopsDict[stopItem.seq] = stopItem.stop
            }
            
            lock.lock()
            routeStopsCache[key] = stopsDict
            lock.unlock()
            
            return stopsDict[seq]
        } catch {
            print("🐛 [DEBUG] Failed to resolve CTB stop ID for \(route)-\(bound) seq \(seq): \(error)")
            return nil
        }
    }
}

// MARK: - Controller / Business Logic
extension ContentView {
    
    // MARK: - 載入所有路線 (供搜尋列與自動完成使用)
    func loadAllRoutes() async {
        do {
            // 使用 Dictionary 來過濾重複，現在加上公司前綴防止覆蓋
            var uniqueSuggestions: [String: RouteSuggestion] = [:]
            
            // ==========================================
            // 1. 載入九巴 (KMB) 路線
            // ==========================================
            if let kmbUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route/") {
                let (kmbData, _) = try await URLSession.shared.data(from: kmbUrl)
                let kmbResponse = try JSONDecoder().decode(KMBRoutesResponse.self, from: kmbData)
                
                for item in kmbResponse.data {
                    // 🌟 核心修復：在 Key 加上 "KMB-" 前綴
                    let key = "KMB-\(item.route)-\(item.bound)"
                    uniqueSuggestions[key] = RouteSuggestion(
                        co: "KMB",
                        route: item.route,
                        bound: item.bound,
                        origin: item.orig_tc,
                        destination: item.dest_tc
                    )
                }
            }
            
            // ==========================================
            // 2. 載入城巴 (CTB) 路線
            // ==========================================
            if let ctbUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/route/ctb") {
                let (ctbData, _) = try await URLSession.shared.data(from: ctbUrl)
                let ctbResponse = try JSONDecoder().decode(CTBRouteResponse.self, from: ctbData)
                
                for item in ctbResponse.data {
                    // 🌟 核心修復：在 Key 加上 "CTB-" 前綴，確保不會蓋掉九巴的同名路線 (如 42C, 2A)
                    let keyO = "CTB-\(item.route)-O"
                    uniqueSuggestions[keyO] = RouteSuggestion(
                        co: "CTB",
                        route: item.route,
                        bound: "O",
                        origin: item.orig_tc,
                        destination: item.dest_tc
                    )
                    
                    let keyI = "CTB-\(item.route)-I"
                    uniqueSuggestions[keyI] = RouteSuggestion(
                        co: "CTB",
                        route: item.route,
                        bound: "I",
                        origin: item.dest_tc,
                        destination: item.orig_tc
                    )
                }
            }
            
            // ==========================================
            // 3. 排序並推送到主執行緒更新 UI
            // ==========================================
            let sortedRoutes = uniqueSuggestions.values.sorted {
                // 如果路線名稱相同 (例如都有 42C)
                if $0.route == $1.route {
                    if $0.co == $1.co {
                        // 同公司則依照去回程排序
                        return $0.bound > $1.bound
                    }
                    // 不同公司則依照公司名排序 (讓城巴九巴排在一起)
                    return $0.co > $1.co
                }
                // 依照路線名稱自然排序 (1, 1A, 2, 2A...)
                return $0.route.localizedStandardCompare($1.route) == .orderedAscending
            }
            
            await MainActor.run {
                self.allRoutes = sortedRoutes
            }
            
        } catch {
            print("❌ 載入所有路線失敗: \(error)")
        }
    }
    
    // 替換你原本 ContentView+Logic.swift 裡的 loadAllStops() 函數
    // MARK: - 1. 完美融合九巴 API 與城巴 CSV 站點
        func loadAllStops() async {
            guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop/") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let response = try JSONDecoder().decode(StopResponse.self, from: data)
                
                var newDict: [String: String] = [:]
                var newInfoDict: [String: StopInfo] = [:]
                
                for stop in response.data {
                    if let latStr = stop.lat, let lonStr = stop.long,
                       let lat = Double(latStr), let lon = Double(lonStr), lat != 0.0, lon != 0.0 {
                        newDict[stop.stop] = stop.name_tc
                        newInfoDict[stop.stop] = stop
                    }
                }
                
                // 🌟 核心修改：利用你的 CSV，把城巴的路線底牌翻出來！
                if let csvPath = Bundle.main.path(forResource: "ctb_routes_all_stops", ofType: "csv") {
                    if let csvContent = try? String(contentsOfFile: csvPath, encoding: .utf8) {
                        let lines = csvContent.components(separatedBy: .newlines)
                        
                        var tempRouteCache: [String: [(route: String, bound: String, seq: Int)]] = [:]
                        
                        for (index, line) in lines.enumerated() {
                            if index == 0 || line.isEmpty { continue }
                            let columns = parseCSVLine(line)
                            if columns.count >= 12 {
                                let routeSeq = columns[1].trimmingCharacters(in: .whitespacesAndNewlines) // 1=去程, 2=回程
                                let stopSeqStr = columns[2].trimmingCharacters(in: .whitespacesAndNewlines)
                                let stopId = columns[3].trimmingCharacters(in: .whitespacesAndNewlines)
                                let stopNameCc = columns[5].trimmingCharacters(in: .whitespacesAndNewlines)
                                let routeName = columns[9].trimmingCharacters(in: .whitespacesAndNewlines) // 如: E21
                                let lonStr = columns[10].trimmingCharacters(in: .whitespacesAndNewlines)
                                let latStr = columns[11].trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                let stopSeq = Int(stopSeqStr) ?? 1
                                
                                // 將 CSV 的方向代碼轉換為 API 使用的 O (Outbound) 和 I (Inbound)
                                let bound = (routeSeq == "1") ? "O" : "I"
                                
                                // 把路線加入該車站的專屬名單中
                                if !stopId.isEmpty && !routeName.isEmpty {
                                    if tempRouteCache[stopId] == nil { tempRouteCache[stopId] = [] }
                                    if !tempRouteCache[stopId]!.contains(where: { $0.route == routeName && $0.bound == bound && $0.seq == stopSeq }) {
                                        tempRouteCache[stopId]!.append((route: routeName, bound: bound, seq: stopSeq))
                                    }
                                }
                                
                                // 同時補齊純城巴站點的座標
                                if let lat = Double(latStr), let lon = Double(lonStr), lat != 0.0, lon != 0.0 {
                                    if newDict[stopId] == nil {
                                        newDict[stopId] = stopNameCc
                                        newInfoDict[stopId] = StopInfo(stop: stopId, name_tc: stopNameCc, lat: latStr, long: lonStr)
                                    }
                                }
                            }
                        }
                        CSVRouteCache.shared.routesForStop = tempRouteCache
                    }
                }
                
                await MainActor.run {
                    self.allStops = Array(newInfoDict.values)
                    self.stopDictionary = newDict
                    self.stopInfoDictionary = newInfoDict
                }
                
                if let userLoc = locationManager.location {
                    await updateNearbyStops(userLocation: userLoc)
                }
            } catch {
                print("Failed to load stops dictionary: \(error)")
            }
        }
        
        func parseCSVLine(_ line: String) -> [String] {
            var result: [String] = []
            var current = ""
            var insideQuotes = false
            for char in line {
                if char == "\"" { insideQuotes.toggle() }
                else if char == "," && !insideQuotes {
                    result.append(current)
                    current = ""
                } else { current.append(char) }
            }
            result.append(current)
            return result
        }
    
    func updateNearbyStops(userLocation: CLLocation) async {
        guard !allStops.isEmpty else { return }
        
        await MainActor.run {
            isSearchingNearby = true
        }
        
        let sorted = await Task.detached(priority: .userInitiated) { () -> [NearbyStopModel] in
            var temp: [NearbyStopModel] = []
            for stop in allStops {
                guard let stopLoc = stop.clLocation else { continue }
                let dist = userLocation.distance(from: stopLoc)
                temp.append(NearbyStopModel(stopInfo: stop, distance: dist))
            }
            temp.sort { $0.distance < $1.distance }
            return Array(temp.prefix(10))
        }.value
        
        var populated: [NearbyStopModel] = []
        for var stopModel in sorted {
            let routes = await fetchRoutesForStop(stopId: stopModel.stopInfo.stop)
            stopModel.routes = routes
            populated.append(stopModel)
        }
        
        await MainActor.run {
            self.nearbyStops = populated
            self.isSearchingNearby = false
        }
    }
    
    // 🌟 純粹刷新畫面上已有車站嘅 ETA，唔重新計 GPS (更快)
    func refreshNearbyETAs() async {
        guard !nearbyStops.isEmpty else { return }
        
        await MainActor.run { isSearchingNearby = true }
        
        var updatedStops = nearbyStops
        for i in 0..<updatedStops.count {
            let routes = await fetchRoutesForStop(stopId: updatedStops[i].stopInfo.stop)
            updatedStops[i].routes = routes
        }
        
        await MainActor.run {
            self.nearbyStops = updatedStops
            self.isSearchingNearby = false
        }
    }
    
    // MARK: - 3. 跨平台抓取九巴與城巴靜態路線 (已移除 ETA API)
        func fetchRoutesForStop(stopId: String) async -> [NearbyRouteModel] {
            let currentRoutes = await MainActor.run { self.allRoutes }
            var finalRouteModels: [NearbyRouteModel] = []
            var processedKMBRouteBounds = Set<String>()
            
            // ==========================================
            // 🔴 1. 九巴端：使用 stop-eta 僅作「路線探索」(不抓取/解析 ETA 時間)
            // ==========================================
            if let kmbUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(stopId)") {
                if let (data, _) = try? await URLSession.shared.data(from: kmbUrl),
                   let response = try? JSONDecoder().decode(StopETAResponse.self, from: data) {
                    
                    var uniqueRoutes: [String: StopETAItem] = [:]
                    for item in response.data where item.service_type == 1 {
                        let key = "\(item.route)-\(item.dir)-\(item.dest_tc)"
                        if uniqueRoutes[key] == nil {
                            uniqueRoutes[key] = item
                        }
                    }
                    
                    for (_, item) in uniqueRoutes {
                        finalRouteModels.append(NearbyRouteModel(
                            co: "KMB", // 🌟 明確指定
                            route: item.route,
                            directionCode: item.dir,
                            destNameTc: item.dest_tc,
                            etas: []
                        ))
                        processedKMBRouteBounds.insert("\(item.route)-\(item.dir)")
                    }
                }
            }
            
            // ==========================================
            // 🟡 2. 城巴端：直接由 CSV 靜態讀取 (完全移除 ETA API)
            // ==========================================
            let expectedCTBRoutes = CSVRouteCache.shared.routesForStop[stopId] ?? []
            
            for expected in expectedCTBRoutes {
                let routeKey = "\(expected.route)-\(expected.bound)"
                
                // 聯營線防重複
                if processedKMBRouteBounds.contains(routeKey) { continue }
                
                let fallbackDest = currentRoutes.first(where: { $0.route == expected.route && $0.bound == expected.bound })?.destination ?? "城巴"
                
                finalRouteModels.append(NearbyRouteModel(
                    co: "CTB", // 🌟 明確指定
                    route: expected.route,
                    directionCode: expected.bound,
                    destNameTc: fallbackDest,
                    etas: []
                ))
            }
            
            return finalRouteModels.sorted { $0.route.localizedStandardCompare($1.route) == .orderedAscending }
        }
    
    func searchRoute(route: String, direction: String? = nil, company: String? = nil, findNearest: Bool = false, targetStopCode: String? = nil, shouldScroll: Bool = false, isRefresh: Bool = false) async {
        guard !route.isEmpty else { return }
        
        let currentDir = direction ?? self.selectedDirection
        
        // 🌟 2. 優先使用傳入的公司，如果沒有就找預設的 (防止你的 Favorites 崩潰)
        let targetCompany = company ?? allRoutes.first(where: { $0.route == route })?.co ?? "KMB"
        
        await MainActor.run {
            if let newDir = direction { self.selectedDirection = newDir }
            self.selectedCompany = targetCompany // 更新全域狀態
            if !isRefresh { isLoading = true; displayData = []; highlightedStopId = nil }
        }
        
        do {
            var results: [StopDisplayModel] = []
            let targetDirectionCode = currentDir == "outbound" ? "O" : "I"
            let dateFormatter = ISO8601DateFormatter()
            let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
            
            // ==========================================
            // 🌟 3. 將下方的 if 判斷從 company 改為 targetCompany
            // ==========================================
            if targetCompany == "KMB" {
                    let routeStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(safeRoute)/\(currentDir)/1")!
                    let etaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-eta/\(safeRoute)/1")!
                    
                    var routeStopReq = URLRequest(url: routeStopUrl)
                    routeStopReq.cachePolicy = .reloadIgnoringLocalCacheData
                    var etaReq = URLRequest(url: etaUrl)
                    etaReq.cachePolicy = .reloadIgnoringLocalCacheData
                    
                    async let fetchRouteStop = URLSession.shared.data(for: routeStopReq)
                    async let fetchEta = URLSession.shared.data(for: etaReq)
                    
                    let (routeStopData, _) = try await fetchRouteStop
                    let (etaData, _) = try await fetchEta
                    
                    let decoder = JSONDecoder()
                    let routeStops = try await decoder.decode(RouteStopResponse.self, from: routeStopData).data
                    let allEtas = try await decoder.decode(ETAResponse.self, from: etaData).data
                    let filteredEtas = allEtas.filter { $0.dir == targetDirectionCode }
                    
                    for routeStop in routeStops {
                        let stopNameTc = stopInfoDictionary[routeStop.stop]?.name_tc ?? stopDictionary[routeStop.stop] ?? "未知車站"
                        let seqInt = Int(routeStop.seq) ?? 0
                        let stopEtas = filteredEtas.filter { $0.seq == seqInt }
                        
                        var parsedEtas: [ETADisplayInfo] = []
                        for etaItem in stopEtas {
                            if let etaString = etaItem.eta, !etaString.isEmpty, let etaDate = dateFormatter.date(from: etaString) {
                                parsedEtas.append(ETADisplayInfo(etaDate: etaDate, remark: etaItem.rmk_tc))
                            }
                        }
                        results.append(StopDisplayModel(seq: seqInt, stopId: routeStop.stop, stopNameTc: stopNameTc, etas: parsedEtas))
                    }
                }
                // ==========================================
                // 🟡 城巴 (CTB) 處理邏輯
                // ==========================================
                else if company == "CTB" {
                    let dirStr = currentDir == "outbound" ? "outbound" : "inbound"
                    let routeStopUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/route-stop/CTB/\(safeRoute)/\(dirStr)")!
                    
                    var routeStopReq = URLRequest(url: routeStopUrl)
                    routeStopReq.cachePolicy = .reloadIgnoringLocalCacheData
                    let (rsData, _) = try await URLSession.shared.data(for: routeStopReq)
                    let routeStops = try JSONDecoder().decode(CTBRouteStopResponse.self, from: rsData).data
                    
                    results = await withTaskGroup(of: StopDisplayModel?.self) { group in
                        for rs in routeStops {
                            group.addTask {
                                var stopNameTc = "車站 \(rs.stop)"
                                var location: CLLocation? = nil
                                
                                // 1. 取車站名稱
                                do {
                                    let stopUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/stop/\(rs.stop)")!
                                    var sReq = URLRequest(url: stopUrl)
                                    sReq.cachePolicy = .returnCacheDataElseLoad
                                    let (sData, _) = try await URLSession.shared.data(for: sReq)
                                    let stopInfo = try JSONDecoder().decode(CTBStopResponse.self, from: sData).data
                                    stopNameTc = stopInfo.name_tc
                                    location = stopInfo.clLocation
                                } catch { }
                                
                                // 2. 取此站 ETA (🌟 改用 JSONSerialization 動態解析，徹底避免 Codable 型別閃退)
                                var parsedEtas: [ETADisplayInfo] = []
                                do {
                                    let etaUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/eta/CTB/\(rs.stop)/\(safeRoute)")!
                                    
                                    print("🐛 [DEBUG] CTB API URL: \(etaUrl.absoluteString)")
                                    
                                    var eReq = URLRequest(url: etaUrl)
                                    eReq.cachePolicy = .reloadIgnoringLocalCacheData
                                    let (eData, _) = try await URLSession.shared.data(for: eReq)
                                    
                                    if let json = try JSONSerialization.jsonObject(with: eData) as? [String: Any],
                                       let dataArr = json["data"] as? [[String: Any]] {
                                        
                                        let formatter = ISO8601DateFormatter()
                                        
                                        for item in dataArr {
                                            let itemDir = (item["dir"] as? String)?.uppercased() ?? ""
                                            
                                            // 🌟 寬鬆解析 seq (防範 API 隨機傳回 String 或 Int)
                                            var itemSeq = -1
                                            if let sInt = item["seq"] as? Int { itemSeq = sInt }
                                            else if let sStr = item["seq"] as? String, let sParsed = Int(sStr) { itemSeq = sParsed }
                                            
                                            let itemEta = item["eta"] as? String ?? ""
                                            let itemRmk = item["rmk_tc"] as? String ?? ""
                                            
                                            if itemDir == targetDirectionCode, !itemEta.isEmpty {
                                                // 🌟 只要 seq 吻合，或是 API 根本沒給 seq (itemSeq == -1) 就強制放行
                                                if itemSeq == rs.seq || itemSeq == -1 {
                                                    var etaDate = formatter.date(from: itemEta)
                                                    if etaDate == nil {
                                                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                                        etaDate = formatter.date(from: itemEta)
                                                        formatter.formatOptions = [.withInternetDateTime]
                                                    }
                                                    
                                                    if let validDate = etaDate {
                                                        parsedEtas.append(ETADisplayInfo(etaDate: validDate, remark: itemRmk))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                } catch { }
                                
                                // 🌟 確保解析出來的 ETA 乖乖由近到遠排序
                                parsedEtas.sort { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
                                
                                return StopDisplayModel(seq: rs.seq, stopId: rs.stop, stopNameTc: stopNameTc, etas: parsedEtas, location: location)
                            }
                        }
                        
                        var collected = [StopDisplayModel]()
                        for await model in group {
                            if let m = model { collected.append(m) }
                        }
                        return collected.sorted { $0.seq < $1.seq }
                    }
                }
                // ==========================================
                // 🟢 聯營線 (JOINT) 合併邏輯！
                // ==========================================
                else if company == "JOINT" {
                    let dirStr = currentDir == "outbound" ? "outbound" : "inbound"
                    
                    // 1. 準備兩家公司的 URL
                    let kmbRouteStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(safeRoute)/\(currentDir)/1")!
                    let kmbEtaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-eta/\(safeRoute)/1")!
                    let ctbRouteStopUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/route-stop/CTB/\(safeRoute)/\(dirStr)")!
                    
                    // 2. 併發下載基礎資料 (九巴車站、九巴全線ETA、城巴車站)
                    async let fetchKmbRs = URLSession.shared.data(from: kmbRouteStopUrl)
                    async let fetchKmbEta = URLSession.shared.data(from: kmbEtaUrl)
                    async let fetchCtbRs = URLSession.shared.data(from: ctbRouteStopUrl)
                    
                    let (kmbRsData, _) = try await fetchKmbRs
                    let (kmbEtaData, _) = try await fetchKmbEta
                    let ctbRsResponse = try? await fetchCtbRs
                    let ctbRsData = ctbRsResponse?.0
                    
                    let kmbStops = try JSONDecoder().decode(RouteStopResponse.self, from: kmbRsData).data
                    let kmbEtas = try JSONDecoder().decode(ETAResponse.self, from: kmbEtaData).data.filter { $0.dir == targetDirectionCode }
                    let ctbStops = (try? JSONDecoder().decode(CTBRouteStopResponse.self, from: ctbRsData ?? Data()).data) ?? []
                    
                    // 3. 利用 TaskGroup 瞬間拉取城巴全線 ETA (加入防封鎖微延遲)
                    let ctbEtaDict = await withTaskGroup(of: (Int, [ETADisplayInfo]).self) { group in
                        for (index, ctbStop) in ctbStops.enumerated() {
                            group.addTask {
                                try? await Task.sleep(nanoseconds: UInt64(index) * 20_000_000) // 防封鎖機制
                                var etas: [ETADisplayInfo] = []
                                
                                if let url = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/eta/CTB/\(ctbStop.stop)/\(safeRoute)"),
                                   let (data, _) = try? await URLSession.shared.data(from: url) {
                                    
                                    // 動態寬鬆解析 CTB ETA
                                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                       let dataArr = json["data"] as? [[String: Any]] {
                                        
                                        let formatter = ISO8601DateFormatter()
                                        for item in dataArr {
                                            let itemDir = (item["dir"] as? String)?.uppercased() ?? ""
                                            let itemEta = item["eta"] as? String ?? ""
                                            
                                            if itemDir == targetDirectionCode, !itemEta.isEmpty {
                                                var etaDate = formatter.date(from: itemEta)
                                                if etaDate == nil {
                                                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                                    etaDate = formatter.date(from: itemEta)
                                                    formatter.formatOptions = [.withInternetDateTime]
                                                }
                                                if let validDate = etaDate {
                                                    etas.append(ETADisplayInfo(etaDate: validDate, remark: item["rmk_tc"] as? String))
                                                }
                                            }
                                        }
                                    }
                                }
                                return (ctbStop.seq, etas) // 回傳：(車站序號, [ETA時間])
                            }
                        }
                        var dict = [Int: [ETADisplayInfo]]()
                        for await (seq, etas) in group { dict[seq] = etas }
                        return dict
                    }
                    
                    // 4. 以「九巴車站」為骨幹，開始縫合 ETA 數據
                    for kmbStop in kmbStops {
                        let seqInt = Int(kmbStop.seq) ?? 0
                        let stopNameTc = stopInfoDictionary[kmbStop.stop]?.name_tc ?? stopDictionary[kmbStop.stop] ?? "未知車站"
                        var combinedEtas: [ETADisplayInfo] = []
                        
                        // A. 塞入九巴的時間 (並加上 "九巴" 標籤)
                        for etaItem in kmbEtas.filter({ $0.seq == seqInt }) {
                            if let etaStr = etaItem.eta, !etaStr.isEmpty, let date = dateFormatter.date(from: etaStr) {
                                let rawRmk = etaItem.rmk_tc ?? ""
                                let finalRmk = rawRmk.isEmpty ? "九巴" : "九巴 - \(rawRmk)"
                                combinedEtas.append(ETADisplayInfo(etaDate: date, remark: finalRmk))
                            }
                        }
                        
                        // B. 塞入城巴的時間 (利用同一個 seqInt 去找對應的車站，加上 "城巴" 標籤)
                        if let ctbEtas = ctbEtaDict[seqInt] {
                            for ctbEta in ctbEtas {
                                let rawRmk = ctbEta.remark ?? ""
                                let finalRmk = rawRmk.isEmpty ? "城巴" : "城巴 - \(rawRmk)"
                                combinedEtas.append(ETADisplayInfo(etaDate: ctbEta.etaDate, remark: finalRmk))
                            }
                        }
                        
                        // C. 重新排序：不管是九巴還城巴，誰先到就排前面！
                        combinedEtas.sort { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
                        
                        // D. 取前三班車，存入結果
                        results.append(StopDisplayModel(seq: seqInt, stopId: kmbStop.stop, stopNameTc: stopNameTc, etas: Array(combinedEtas.prefix(3))))
                    }
                }
                
                
                // ==========================================
                // 共用邏輯：計算最近車站與 UI 更新
                // ==========================================
                var targetId: String? = nil
                if findNearest {
                    if let userLoc = locationManager.location, !results.isEmpty {
                        var minDistance: CLLocationDistance = .infinity
                        for rs in results {
                            let loc: CLLocation? = rs.location ?? stopInfoDictionary[rs.stopId]?.clLocation ?? allStops.first(where: { $0.stop == rs.stopId })?.clLocation
                            if let stopLoc = loc {
                                let dist = userLoc.distance(from: stopLoc)
                                if dist < minDistance {
                                    minDistance = dist
                                    targetId = rs.id
                                }
                            }
                        }
                    }
                } else if let code = targetStopCode {
                    if let exactMatch = results.first(where: { $0.stopId == code }) {
                        targetId = exactMatch.id
                    } else {
                        // 如果沒有精確匹配（例如城巴 CSV 的舊 ID 與 API 的新 6 位數 ID），我們透過名稱或經緯度來匹配
                        let cleanTargetName = stopInfoDictionary[code]?.name_tc.replacingOccurrences(of: "\\s*\\([^)]+\\)\\s*$", with: "", options: .regularExpression) ?? ""
                        
                        let targetLoc = stopInfoDictionary[code]?.clLocation
                        
                        // 先嘗試名稱匹配
                        if let nameMatch = results.first(where: { rs in
                            let cleanRsName = rs.stopNameTc.replacingOccurrences(of: "\\s*\\([^)]+\\)\\s*$", with: "", options: .regularExpression)
                            return !cleanTargetName.isEmpty && cleanRsName == cleanTargetName
                        }) {
                            targetId = nameMatch.id
                        } else if let targetLoc = targetLoc {
                            // 再嘗試距離最接近匹配（小於 100 米）
                            var minD: CLLocationDistance = 100
                            var bestRs: StopDisplayModel? = nil
                            for rs in results {
                                let loc: CLLocation? = rs.location ?? stopInfoDictionary[rs.stopId]?.clLocation
                                if let stopLoc = loc {
                                    let d = targetLoc.distance(from: stopLoc)
                                    if d < minD {
                                        minD = d
                                        bestRs = rs
                                    }
                                }
                            }
                            targetId = bestRs?.id
                        }
                    }
                } else {
                    targetId = highlightedStopId
                }
                
                await MainActor.run {
                    self.highlightedStopId = targetId
                    
                    if results.isEmpty {
                        systemMessage = "沒有找到路線 \(route) 的 \(currentDir == "outbound" ? "去程" : "回程") 班次數據。"
                        if !isRefresh { displayData = [] }
                    } else {
                        displayData = results
                    }
                    
                    if shouldScroll { self.scrollTriggerId = UUID() }
                    if !isRefresh { isLoading = false }
                }
            } catch {
                await MainActor.run {
                    systemMessage = "無法加載數據或找不到此路線。"
                    if !isRefresh { displayData = []; isLoading = false }
                }
            }
        }
    
    // MARK: - 實時背景同步與追蹤更新函數
    func syncActiveTimer() async {
        guard let timer = activeTimer, !timer.stopId.isEmpty else { return }
        
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(timer.stopId)") else { return }
        
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(StopETAResponse.self, from: data)
            
            let targetDirCode = timer.direction == "outbound" ? "O" : "I"
            let matchedItems = response.data.filter { $0.route == timer.routeName && $0.dir == targetDirCode }
            let sortedItems = matchedItems.sorted { $0.eta_seq < $1.eta_seq }
            
            let dateFormatter = ISO8601DateFormatter()
            if let firstEtaItem = sortedItems.first,
               let etaString = firstEtaItem.eta,
               let newEtaDate = dateFormatter.date(from: etaString) {
                
                let difference = abs(newEtaDate.timeIntervalSince(timer.etaDate))
                if difference > 10 {
                    print("🐛 [DEBUG] 偵測到最新巴士真實班次已更動！正在進行動態重設...")
                    
                    await MainActor.run {
                        withAnimation {
                            self.activeTimer?.etaDate = newEtaDate
                            self.activeTimer?.targetAlertDate = newEtaDate.addingTimeInterval(-120)
                        }
                    }
                    
                    let alertDate = newEtaDate.addingTimeInterval(-120)
                    if alertDate.timeIntervalSince(Date()) > 0 {
                        scheduleLocalNotification(
                            routeName: timer.routeName,
                            destination: timer.destination,
                            alertDate: alertDate
                        )
                    }
                    
                    updateLiveActivity(etaDate: newEtaDate)
                }
            }
        } catch {
            print("🐛 [DEBUG] 背景計時器即時同步失敗: \(error)")
        }
    }
    
    func updateLiveActivity(etaDate: Date) {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                
                let expireDate = etaDate.addingTimeInterval(1 * 60)
                await activity.update(ActivityContent(state: state, staleDate: expireDate))
            }
        }
    }
    
    func formattedTime(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    func scheduleLocalNotification(routeName: String, destination: String, alertDate: Date) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
        
        let content = UNMutableNotificationContent()
        content.title = "巴士即將抵達！"
        content.body = "您設定的 \(routeName) (往 \(destination)) 巴士即將在 2 分鐘內抵達，請準備上車。"
        content.sound = .default
        
        let timeInterval = alertDate.timeIntervalSince(Date())
        guard timeInterval > 0 else { return }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let request = UNNotificationRequest(identifier: "KMBTimeAlarm", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule local notification: \(error)")
            }
        }
    }
    
    func startLiveActivity(routeName: String, destination: String, stationName: String, etaDate: Date, startTime: Date) {
        if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                let attributes = BusETAAttributes(routeName: routeName, destination: destination, stationName: stationName, startTime: startTime)
                let remaining = Int(etaDate.timeIntervalSince(Date()))
                let state = BusETAAttributes.ContentState(etaDate: etaDate, remainingSeconds: remaining)
                
                let expireDate = etaDate.addingTimeInterval(1 * 60)
                let content = ActivityContent(state: state, staleDate: expireDate)
                let _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                print("Error starting Live Activity: \(error.localizedDescription)")
            }
        }
    }
    
    func endLiveActivity() {
        Task {
            for activity in Activity<BusETAAttributes>.activities {
                let state = BusETAAttributes.ContentState(etaDate: activity.content.state.etaDate, remainingSeconds: 0)
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
    
    func reconnectActiveLiveActivity() {
        for activity in Activity<BusETAAttributes>.activities {
            let attribs = activity.attributes
            let state = activity.content.state
            
            if state.etaDate.timeIntervalSince(Date()) > 0 {
                if self.activeTimer == nil {
                    self.activeTimer = ActiveTimerModel(
                        routeName: attribs.routeName,
                        destination: attribs.destination,
                        etaDate: state.etaDate,
                        targetAlertDate: state.etaDate.addingTimeInterval(-120),
                        startTime: attribs.startTime,
                        stopId: "",
                        direction: "",
                        stationName: attribs.stationName
                    )
                    print("成功重新連接背景計時器: \(attribs.routeName)")
                }
            } else {
                print("🐛 [DEBUG] 發現過期卡片 \(attribs.routeName)，立即刪除！")
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }
}
