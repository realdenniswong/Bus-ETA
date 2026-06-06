import SwiftUI
import CoreLocation
import Combine
import UserNotifications
import ActivityKit

fileprivate class CSVRouteCache {
    static let shared = CSVRouteCache()
    var routesForStop: [String: [(route: String, bound: String)]] = [:]
}

// MARK: - Controller / Business Logic
extension ContentView {
    
    // MARK: - Network Functions
    func loadAllRoutes() async {
        guard let kmbUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route/"),
              let ctbUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/route/CTB") else { return }
        do {
            async let fetchKMB = URLSession.shared.data(from: kmbUrl)
            async let fetchCTB = URLSession.shared.data(from: ctbUrl)
            
            let (kmbData, _) = try await fetchKMB
            let kmbResponse = try JSONDecoder().decode(AllRoutesResponse.self, from: kmbData)
            
            let (ctbData, _) = try await fetchCTB
            let ctbResponse = try JSONDecoder().decode(CTBRouteResponse.self, from: ctbData)
            
            var uniqueSuggestions: [String: RouteSuggestion] = [:]
            
            // 1. 載入九巴路線 (打底)
            for item in kmbResponse.data {
                let key = "\(item.route)-\(item.bound)"
                if uniqueSuggestions[key] == nil {
                    uniqueSuggestions[key] = RouteSuggestion(co: "KMB", route: item.route, bound: item.bound, origin: item.orig_tc, destination: item.dest_tc)
                }
            }
            
            // 2. 載入城巴路線 (比對聯營)
            for item in ctbResponse.data {
                // 處理去程 (O)
                let keyO = "\(item.route)-O"
                if uniqueSuggestions[keyO] != nil {
                    // 已經存在於九巴字典中 -> 這是聯營線！
                    uniqueSuggestions[keyO] = RouteSuggestion(co: "JOINT", route: item.route, bound: "O", origin: item.orig_tc, destination: item.dest_tc)
                } else {
                    // 九巴沒有 -> 這是城巴獨營線
                    uniqueSuggestions[keyO] = RouteSuggestion(co: "CTB", route: item.route, bound: "O", origin: item.orig_tc, destination: item.dest_tc)
                }
                
                // 處理回程 (I)
                let keyI = "\(item.route)-I"
                if uniqueSuggestions[keyI] != nil {
                    uniqueSuggestions[keyI] = RouteSuggestion(co: "JOINT", route: item.route, bound: "I", origin: item.dest_tc, destination: item.orig_tc)
                } else {
                    uniqueSuggestions[keyI] = RouteSuggestion(co: "CTB", route: item.route, bound: "I", origin: item.dest_tc, destination: item.orig_tc)
                }
            }
            
            let sortedRoutes = uniqueSuggestions.values.sorted {
                if $0.route == $1.route { return $0.bound > $1.bound }
                return $0.route.localizedStandardCompare($1.route) == .orderedAscending
            }
            
            await MainActor.run {
                self.allRoutes = sortedRoutes
            }
        } catch {
            print("🐛 [DEBUG] Failed to load all routes: \(error)")
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
                        
                        var tempRouteCache: [String: [(route: String, bound: String)]] = [:]
                        
                        for (index, line) in lines.enumerated() {
                            if index == 0 || line.isEmpty { continue }
                            let columns = parseCSVLine(line)
                            if columns.count >= 12 {
                                let routeSeq = columns[1].trimmingCharacters(in: .whitespacesAndNewlines) // 1=去程, 2=回程
                                let stopId = columns[3].trimmingCharacters(in: .whitespacesAndNewlines)
                                let stopNameCc = columns[5].trimmingCharacters(in: .whitespacesAndNewlines)
                                let routeName = columns[9].trimmingCharacters(in: .whitespacesAndNewlines) // 如: E21
                                let lonStr = columns[10].trimmingCharacters(in: .whitespacesAndNewlines)
                                let latStr = columns[11].trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                // 將 CSV 的方向代碼轉換為 API 使用的 O (Outbound) 和 I (Inbound)
                                let bound = (routeSeq == "1") ? "O" : "I"
                                
                                // 把路線加入該車站的專屬名單中
                                if !stopId.isEmpty && !routeName.isEmpty {
                                    if tempRouteCache[stopId] == nil { tempRouteCache[stopId] = [] }
                                    if !tempRouteCache[stopId]!.contains(where: { $0.route == routeName && $0.bound == bound }) {
                                        tempRouteCache[stopId]!.append((route: routeName, bound: bound))
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
    
    // MARK: - 3. 跨平台抓取九巴與城巴 ETA
    func fetchRoutesForStop(stopId: String) async -> [NearbyRouteModel] {
            let currentRoutes = await MainActor.run { self.allRoutes }
            let dateFormatter = ISO8601DateFormatter()
            var finalRouteModels: [NearbyRouteModel] = []
            var processedKMBRouteBounds = Set<String>() // 紀錄九巴已經處理過的路線
            
            // ==========================================
            // 🔴 1. 九巴端 ETA 數據
            // ==========================================
            if let kmbUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(stopId)") {
                if let (data, _) = try? await URLSession.shared.data(from: kmbUrl),
                   let response = try? JSONDecoder().decode(StopETAResponse.self, from: data) {
                    
                    var groupedKMB: [String: [StopETAItem]] = [:]
                    for item in response.data where item.service_type == 1 {
                        let key = "\(item.route)-\(item.dir)-\(item.dest_tc)"
                        groupedKMB[key, default: []].append(item)
                    }
                    
                    let kmbRoutes = await withTaskGroup(of: NearbyRouteModel?.self) { group in
                        for (_, items) in groupedKMB {
                            guard let first = items.first else { continue }
                            group.addTask {
                                let sortedItems = items.sorted { $0.eta_seq < $1.eta_seq }
                                var etaInfos: [ETADisplayInfo] = []
                                let boundCode = first.dir
                                let dirStr = boundCode == "O" ? "outbound" : "inbound"
                                
                                let isJoint = currentRoutes.contains(where: { $0.route == first.route && $0.bound == boundCode && $0.co == "JOINT" })
                                
                                for etaItem in sortedItems {
                                    if let etaString = etaItem.eta, let etaDate = dateFormatter.date(from: etaString) {
                                        let rawRmk = etaItem.rmk_tc ?? ""
                                        let finalRmk = (isJoint && rawRmk.isEmpty) ? "九巴" : (!isJoint ? rawRmk : "九巴 - \(rawRmk)")
                                        etaInfos.append(ETADisplayInfo(etaDate: etaDate, remark: finalRmk))
                                    }
                                }
                                
                                if isJoint {
                                    let safeRoute = first.route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? first.route
                                    if let ctbRsUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/route-stop/CTB/\(safeRoute)/\(dirStr)"),
                                       let (csData, _) = try? await URLSession.shared.data(from: ctbRsUrl),
                                       let ctbStops = try? JSONDecoder().decode(CTBRouteStopResponse.self, from: csData).data,
                                       let matchedStop = ctbStops.first(where: { $0.seq == first.eta_seq }),
                                       let etaUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/eta/CTB/\(matchedStop.stop)/\(safeRoute)") {
                                        
                                        if let (eData, _) = try? await URLSession.shared.data(from: etaUrl),
                                           let json = try? JSONSerialization.jsonObject(with: eData) as? [String: Any],
                                           let dataArr = json["data"] as? [[String: Any]] {
                                            for item in dataArr {
                                                let itemDir = (item["dir"] as? String)?.uppercased() ?? ""
                                                let itemEta = item["eta"] as? String ?? ""
                                                let itemRmk = item["rmk_tc"] as? String ?? ""
                                                if itemDir == boundCode, !itemEta.isEmpty {
                                                    var date = dateFormatter.date(from: itemEta)
                                                    if date == nil {
                                                        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                                        date = dateFormatter.date(from: itemEta)
                                                        dateFormatter.formatOptions = [.withInternetDateTime]
                                                    }
                                                    if let validDate = date {
                                                        etaInfos.append(ETADisplayInfo(etaDate: validDate, remark: itemRmk.isEmpty ? "城巴" : "城巴 - \(itemRmk)"))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                
                                etaInfos.sort { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
                                return NearbyRouteModel(route: first.route, directionCode: first.dir, destNameTc: first.dest_tc, etas: etaInfos.isEmpty ? [ETADisplayInfo(etaDate: nil, remark: "暫無服務")] : Array(etaInfos.prefix(3)))
                            }
                        }
                        var collected = [NearbyRouteModel]()
                        for await res in group { if let r = res { collected.append(r) } }
                        return collected
                    }
                    
                    finalRouteModels.append(contentsOf: kmbRoutes)
                    // 標記已經處理過的九巴路線
                    for r in kmbRoutes {
                        processedKMBRouteBounds.insert("\(r.route)-\(r.directionCode)")
                    }
                }
            }
            
            // ==========================================
            // 🟡 2. 🌟 終極解法：城巴路線直接由 CSV 說了算！
            // ==========================================
            // 直接從我們一開始讀好的 CSV 中，拿出這座車站「理應包含」的所有城巴路線！
            let expectedCTBRoutes = CSVRouteCache.shared.routesForStop[stopId] ?? []
            var fetchedCTBEtas: [String: [ETADisplayInfo]] = [:]
            
            // 呼叫一次城巴綜合 API，把目前有車的時間先收集起來
            if let ctbStopUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/eta/CTB/\(stopId)/ALL") {
                if let (eData, _) = try? await URLSession.shared.data(from: ctbStopUrl),
                   let json = try? JSONSerialization.jsonObject(with: eData) as? [String: Any],
                   let dataArr = json["data"] as? [[String: Any]] {
                    
                    for item in dataArr {
                        let route = item["route"] as? String ?? ""
                        let dirStr = item["dir"] as? String ?? "O"
                        let itemEta = item["eta"] as? String ?? ""
                        let itemRmk = item["rmk_tc"] as? String ?? ""
                        
                        guard !route.isEmpty, !itemEta.isEmpty else { continue }
                        
                        var date = dateFormatter.date(from: itemEta)
                        if date == nil {
                            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            date = dateFormatter.date(from: itemEta)
                            dateFormatter.formatOptions = [.withInternetDateTime]
                        }
                        
                        if let validDate = date {
                            let key = "\(route)-\(dirStr)"
                            let displayInfo = ETADisplayInfo(etaDate: validDate, remark: itemRmk.isEmpty ? "城巴" : itemRmk)
                            fetchedCTBEtas[key, default: []].append(displayInfo)
                        }
                    }
                }
            }
            
            // 🌟 核心魔法：根據 CSV 名單，確保每一條路線都有上榜！
            for expected in expectedCTBRoutes {
                let routeKey = "\(expected.route)-\(expected.bound)"
                
                // 如果這條線是聯營線，而且上半部九巴已經處理過了，直接跳過防重複
                if processedKMBRouteBounds.contains(routeKey) { continue }
                
                // 去找這條線的目的地名稱（若沒找到就顯示「城巴」）
                let fallbackDest = currentRoutes.first(where: { $0.route == expected.route && $0.bound == expected.bound })?.destination ?? "城巴"
                
                var etas = fetchedCTBEtas[routeKey] ?? []
                etas.sort { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
                
                // 🛡️ 無敵防禦：如果這條 CSV 寫明有的線，API 卻說沒 ETA（例如凌晨收車的 E21）
                // 我們主動給它塞入「暫無服務」，確保它永遠不會消失！
                if etas.isEmpty {
                    etas.append(ETADisplayInfo(etaDate: nil, remark: "暫無服務"))
                }
                
                finalRouteModels.append(NearbyRouteModel(
                    route: expected.route,
                    directionCode: expected.bound,
                    destNameTc: fallbackDest,
                    etas: Array(etas.prefix(3))
                ))
            }
            
            return finalRouteModels.sorted { $0.route.localizedStandardCompare($1.route) == .orderedAscending }
        }
    
    func searchRoute(route: String, direction: String? = nil, findNearest: Bool = false, targetStopCode: String? = nil, shouldScroll: Bool = false, isRefresh: Bool = false) async {
            guard !route.isEmpty else { return }
            
            let currentDir = direction ?? self.selectedDirection
            let company = allRoutes.first(where: { $0.route == route })?.co ?? "KMB"
            
            await MainActor.run {
                if let newDir = direction { self.selectedDirection = newDir }
                if !isRefresh { isLoading = true; displayData = []; highlightedStopId = nil }
            }
            
            do {
                var results: [StopDisplayModel] = []
                let targetDirectionCode = currentDir == "outbound" ? "O" : "I"
                let dateFormatter = ISO8601DateFormatter()
                
                let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
                
                // ==========================================
                // 🔴 九巴 (KMB) 處理邏輯
                // ==========================================
                if company == "KMB" {
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
                    targetId = results.first(where: { $0.stopId == code })?.id
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
    
    // 🌟 NEW: Fetch and Match ETA specifically for Favorites list
    func refreshFavoritesETAs() async {
            let userLoc = await MainActor.run { self.locationManager.location }
            let currentFavs = await MainActor.run { self.favoritesManager.favoriteRoutes }
            let currentRoutes = await MainActor.run { self.allRoutes }
            let currentStopInfoDict = await MainActor.run { self.stopInfoDictionary }
            let currentStopDict = await MainActor.run { self.stopDictionary }
            let currentAllStops = await MainActor.run { self.allStops }
            
            await MainActor.run { isRefreshingFavorites = true }
            
            await withTaskGroup(of: Void.self) { group in
                for fav in currentFavs {
                    group.addTask {
                        let route = fav.route
                        let currentDir = fav.direction
                        let boundCode = currentDir == "outbound" ? "O" : "I"
                        
                        let company = currentRoutes.first(where: { $0.route == route && $0.bound == boundCode })?.co ?? "KMB"
                        let safeRoute = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? route
                        
                        var nearestStopCode: String? = nil
                        var nearestSeq: Int = 1
                        var nearestStopName: String = "未知車站"
                        var etaInfos: [ETADisplayInfo] = []
                        let dateFormatter = ISO8601DateFormatter()
                        
                        // ==========================================
                        // 核心修正：將所有數據獲取包在不中斷的 do-catch 內
                        // ==========================================
                        do {
                            // 1. 定位車站
                            if company == "KMB" || company == "JOINT" {
                                let routeStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(safeRoute)/\(currentDir)/1")!
                                let (routeStopData, _) = try await URLSession.shared.data(from: routeStopUrl)
                                let routeStops = try JSONDecoder().decode(RouteStopResponse.self, from: routeStopData).data
                                
                                if let firstStop = routeStops.first {
                                    nearestStopCode = firstStop.stop
                                    nearestSeq = Int(firstStop.seq) ?? 1
                                    nearestStopName = currentStopInfoDict[firstStop.stop]?.name_tc ?? currentStopDict[firstStop.stop] ?? "未知車站"
                                }
                                
                                if let userLoc = userLoc {
                                    var minDistance: CLLocationDistance = .infinity
                                    for rs in routeStops {
                                        let loc = currentStopInfoDict[rs.stop]?.clLocation ?? currentAllStops.first(where: { $0.stop == rs.stop })?.clLocation
                                        if let stopLoc = loc {
                                            let dist = userLoc.distance(from: stopLoc)
                                            if dist < minDistance {
                                                minDistance = dist
                                                nearestStopCode = rs.stop
                                                nearestSeq = Int(rs.seq) ?? 1
                                                nearestStopName = currentStopInfoDict[rs.stop]?.name_tc ?? currentStopDict[rs.stop] ?? "未知車站"
                                            }
                                        }
                                    }
                                }
                            } else if company == "CTB" {
                                let routeStopUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/route-stop/CTB/\(safeRoute)/\(currentDir)")!
                                let (rsData, _) = try await URLSession.shared.data(from: routeStopUrl)
                                let ctbStops = try JSONDecoder().decode(CTBRouteStopResponse.self, from: rsData).data
                                
                                if let firstStop = ctbStops.first {
                                    nearestStopCode = firstStop.stop
                                    nearestSeq = firstStop.seq
                                }
                                
                                if let code = nearestStopCode {
                                    let sUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/stop/\(code)")!
                                    if let (sData, _) = try? await URLSession.shared.data(from: sUrl),
                                       let stopDetail = try? JSONDecoder().decode(CTBStopResponse.self, from: sData).data {
                                        nearestStopName = stopDetail.name_tc
                                    }
                                }
                            }
                            
                            // 2. 獲取九巴 ETA
                            if (company == "KMB" || company == "JOINT"), let stopCode = nearestStopCode {
                                // 🌟 這裡加上個別的 try? 確保即使單一營運商壞掉，也不會拖累整條路線直接跳進極限 catch
                                if let etaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(stopCode)"),
                                   let (etaData, _) = try? await URLSession.shared.data(from: etaUrl),
                                   let response = try? JSONDecoder().decode(StopETAResponse.self, from: etaData) {
                                    let matched = response.data.filter { $0.route == route && $0.dir == boundCode && $0.service_type == 1 }
                                    for item in matched {
                                        if let etaStr = item.eta, let date = dateFormatter.date(from: etaStr) {
                                            etaInfos.append(ETADisplayInfo(etaDate: date, remark: item.rmk_tc))
                                        }
                                    }
                                }
                            }
                            
                            // 3. 獲取城巴 ETA
                            if (company == "CTB" || company == "JOINT") {
                                var ctbStopId = nearestStopCode
                                
                                if company == "JOINT" {
                                    let ctbRsUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/route-stop/CTB/\(safeRoute)/\(currentDir)")!
                                    if let (csData, _) = try? await URLSession.shared.data(from: ctbRsUrl),
                                       let ctbStops = try? JSONDecoder().decode(CTBRouteStopResponse.self, from: csData).data,
                                       let matchedStop = ctbStops.first(where: { $0.seq == nearestSeq }) {
                                        ctbStopId = matchedStop.stop
                                    }
                                }
                                
                                if let ctbStop = ctbStopId {
                                    let etaUrl = URL(string: "https://rt.data.gov.hk/v2/transport/citybus/eta/CTB/\(ctbStop)/\(safeRoute)")!
                                    // 🌟 使用 try? 降級：若城巴收車 API 報錯 404，不拋出異常，僅視為空數據
                                    if let (eData, _) = try? await URLSession.shared.data(from: etaUrl),
                                       let json = try? JSONSerialization.jsonObject(with: eData) as? [String: Any],
                                       let dataArr = json["data"] as? [[String: Any]] {
                                        
                                        for item in dataArr {
                                            let itemDir = (item["dir"] as? String)?.uppercased() ?? ""
                                            let itemEta = item["eta"] as? String ?? ""
                                            
                                            if itemDir == boundCode, !itemEta.isEmpty {
                                                var etaDate = dateFormatter.date(from: itemEta)
                                                if etaDate == nil {
                                                    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                                    etaDate = dateFormatter.date(from: itemEta)
                                                    dateFormatter.formatOptions = [.withInternetDateTime]
                                                }
                                                if let validDate = etaDate {
                                                    etaInfos.append(ETADisplayInfo(etaDate: validDate, remark: item["rmk_tc"] as? String))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } catch {
                            print("🐛 [DEBUG] Base routing network issue for \(fav.route): \(error)")
                        }
                        
                        // ==========================================
                        // 🌟 核心保證：不論上面 do-catch 內部的 API 是成功還是失敗爆開，
                        // 最終都一定會跑來這裡，把計算完的結果（哪怕是空陣列）寫進主線程字典。
                        // ==========================================
                        etaInfos.sort { ($0.etaDate ?? Date.distantFuture) < ($1.etaDate ?? Date.distantFuture) }
                        let firstEta = etaInfos.first?.etaDate
                        
                        let info = FavoriteETA(stopName: nearestStopName, etaDate: firstEta)
                        await MainActor.run {
                            self.favoriteETAs[fav.id] = info
                        }
                    }
                }
            }
            
            await MainActor.run { isRefreshingFavorites = false }
        }
}
