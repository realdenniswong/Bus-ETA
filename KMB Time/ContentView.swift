//
//  ContentView.swift
//  KMB Time
//
//  Created by Dennis Wong on 5/31/26.
//

import SwiftUI
import CoreLocation
import Combine
import UserNotifications

// MARK: - Data Models
struct StopResponse: Codable { let data: [StopInfo] }
struct StopInfo: Codable {
    let stop: String
    let name_tc: String
    let name_en: String
    let lat: String?
    let long: String?
}

extension StopInfo {
    var clLocation: CLLocation? {
        guard let latStr = lat, let longStr = long,
              let latitude = Double(latStr), let longitude = Double(longStr) else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
}

struct RouteStopResponse: Codable { let data: [RouteStop] }
struct RouteStop: Codable {
    let seq: String
    let stop: String
}

struct ETAResponse: Codable { let data: [ETAItem] }
struct ETAItem: Codable {
    let seq: Int
    let dir: String
    let eta: String?
    let rmk_tc: String?
}

struct ETADisplayInfo: Identifiable, Hashable {
    let id = UUID()
    let etaDate: Date?
    let remark: String?
}

struct StopDisplayModel: Identifiable {
    let id = UUID()
    let seq: Int
    let stopNameTc: String
    let stopNameEn: String
    let etas: [ETADisplayInfo]
}

struct NearbyStopModel: Identifiable {
    let id = UUID()
    let stopInfo: StopInfo
    let distance: CLLocationDistance
    var routes: [NearbyRouteModel] = []
}

struct NearbyRouteModel: Identifiable {
    let id = UUID()
    let route: String
    let directionCode: String // "O" or "I"
    let destNameEn: String
    let destNameTc: String
    let etas: [ETADisplayInfo]
}

struct StopETAResponse: Codable {
    let data: [StopETAItem]
}

struct StopETAItem: Codable {
    let co: String
    let route: String
    let dir: String
    let service_type: Int
    let dest_tc: String
    let dest_en: String
    let eta_seq: Int
    let eta: String?
    let rmk_tc: String?
    let rmk_en: String?
}

// MARK: - User Interface
struct ContentView: View {
    @State private var searchText = ""
    @State private var selectedDirection = "outbound" // Tracks the selected direction
    
    @State private var stopDictionary: [String: String] = [:]
    @State private var stopInfoDictionary: [String: StopInfo] = [:]
    @State private var displayData: [StopDisplayModel] = []
    
    @State private var isLoading = false
    @State private var systemMessage = "搜尋九巴路線 (例如 1A, 281A)"
    
    // Nearby Location States
    @StateObject private var locationManager = LocationManager()
    @State private var allStops: [StopInfo] = []
    @State private var nearbyStops: [NearbyStopModel] = []
    @State private var expandedStopIds: Set<String> = []
    @State private var isSearchingNearby = false
    
    // Explicit Navigation Title State
    @State private var navigationTitle = "九巴即時到站"
    
    // Auto-refresh timer to keep ETA countdowns fresh (ticks every 30 seconds)
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    
    // Local clock timer to update countdowns smoothly (ticks every 1 second)
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var currentTime = Date()
    
    // Active Timer and Alert States
    @State private var activeTimer: ActiveTimerModel? = nil
    @State private var showingAddTimerAlert = false
    @State private var showingTimerCompletedAlert = false
    @State private var timerTargetDate: Date? = nil
    @State private var timerRouteName = ""
    @State private var timerDestination = ""
    
    // Auto-scroll target Stop ID/Name
    @State private var targetScrollStopName: String? = nil
    
    init() {
        // Remove Segmented Control white background track to match background color
        UISegmentedControl.appearance().backgroundColor = .clear
    }
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let timer = activeTimer {
                        activeTimerCard(timer: timer)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                    
                    if searchText.isEmpty {
                        nearbyDashboardSection
                    } else {
                        // Segmented direction switcher inside ScrollView content
                        Picker("Direction", selection: $selectedDirection) {
                            Text("去程 (Outbound)").tag("outbound")
                            Text("回程 (Inbound)").tag("inbound")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedDirection) { _ in
                            if !searchText.isEmpty {
                                Task {
                                    await searchRoute(route: searchText.uppercased())
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        
                        timetableSection
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(themeBackground)
            .navigationTitle(searchText.isEmpty ? "九巴即時到站" : navigationTitle)
            .navigationBarTitleDisplayMode(.large) // Native large title support
            .searchable(text: $searchText, prompt: "輸入路線 (例如 1A)")
            .onSubmit(of: .search) {
                Task {
                    await searchRoute(route: searchText.uppercased())
                }
            }
            .onChange(of: searchText) { newValue in
                if newValue.isEmpty {
                    displayData = []
                    navigationTitle = "九巴即時到站"
                } else {
                    navigationTitle = newValue.uppercased()
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("正在獲取數據...")
                } else if displayData.isEmpty && !searchText.isEmpty {
                    Text(systemMessage)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .toolbar {
                if !searchText.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            searchText = ""
                            displayData = []
                            navigationTitle = "九巴即時到站"
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .fontWeight(.bold)
                                Text("返回")
                            }
                        }
                    }
                }
            }
            .onReceive(refreshTimer) { _ in
                // Automatically refresh ETAs when the app remains open
                Task {
                    if searchText.isEmpty {
                        if let location = locationManager.location {
                            await updateNearbyStops(userLocation: location)
                        }
                    } else if !displayData.isEmpty {
                        await searchRoute(route: searchText.uppercased())
                    }
                }
            }
            .onReceive(clockTimer) { _ in
                currentTime = Date()
                if let timer = activeTimer {
                    let secondsLeft = timer.targetAlertDate.timeIntervalSince(currentTime)
                    if secondsLeft <= 0 {
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        showingTimerCompletedAlert = true
                        activeTimer = nil
                        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
                    }
                }
            }
            .onChange(of: displayData.isEmpty) { isEmpty in
                if !isEmpty, let target = targetScrollStopName {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        targetScrollStopName = nil
                    }
                }
            }
            .alert("設定巴士抵站提醒", isPresented: $showingAddTimerAlert) {
                Button("設定提醒", role: .none) {
                    if let etaDate = timerTargetDate {
                        // Request notification permissions dynamically and schedule background reminder
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                            if granted {
                                scheduleLocalNotification(
                                    routeName: timerRouteName,
                                    destination: timerDestination,
                                    alertDate: etaDate.addingTimeInterval(-120)
                                )
                            }
                        }
                        
                        withAnimation {
                            activeTimer = ActiveTimerModel(
                                routeName: timerRouteName,
                                destination: timerDestination,
                                etaDate: etaDate,
                                targetAlertDate: etaDate.addingTimeInterval(-120)
                            )
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("您是否要為 \(timerRouteName) 路線設定提醒？系統將在巴士預計抵達前 2 分鐘（即 \(formattedTime(timerTargetDate?.addingTimeInterval(-120) ?? Date()))）提醒您。")
            }
            .alert("巴士即將抵達！", isPresented: $showingTimerCompletedAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("您設定的巴士即將在 2 分鐘內抵達，請準備上車。")
            }
            .task {
                await loadAllStops()
                if locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways {
                    locationManager.requestLocation()
                }
                // Request background alert permissions on startup
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
            .onChange(of: locationManager.location) { _ in
                if let location = locationManager.location {
                    Task {
                        await updateNearbyStops(userLocation: location)
                    }
                }
            }
        }
    }
}
    
    // MARK: - Core Theme Background (Pure Native Apple Style)
    private var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
    
    // MARK: - Timetable Route Content Section
    private var timetableSection: some View {
        Group {
            if !displayData.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayData.enumerated()), id: \.element.id) { index, stop in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(Color(red: 0.65, green: 0.08, blue: 0.12)) // KMB Red
                                    .frame(width: 12, height: 12)
                                    .padding(.top, 6)
                                
                                if index < displayData.count - 1 {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(width: 2)
                                        .frame(maxHeight: .infinity)
                                }
                            }
                            .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(stop.seq). \(stop.stopNameTc)")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                    Text(stop.stopNameEn)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                // Always displays exactly 3 lines of ETAs, filling blank spaces with "-"
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(0..<3, id: \.self) { index in
                                        let etaInfo = index < stop.etas.count ? stop.etas[index] : nil
                                        if let etaInfo = etaInfo, let etaDate = etaInfo.etaDate {
                                            let minutesLeft = max(0, Int(etaDate.timeIntervalSince(currentTime) / 60))
                                            let remark = etaInfo.remark ?? ""
                                            let formattedRemark = remark.isEmpty ? "" : " (\(remark))"
                                            Text("\(minutesLeft)分\(formattedRemark)")
                                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                .foregroundColor(.primary)
                                        } else {
                                            Text("-")
                                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                .foregroundColor(.primary)
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, index < displayData.count - 1 ? 20 : 0)
                        }
                        .id(stop.stopNameTc)
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(14)
                .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
            }
        }
    }
    
    // MARK: - Nearby Dashboard View
    @ViewBuilder
    private var nearbyDashboardSection: some View {
        // Stop Header
        HStack {
            Text("附近巴士站")
                .font(.title2)
                .fontWeight(.bold)
            
            Spacer()
            
            if isSearchingNearby {
                ProgressView()
            } else if locationManager.location != nil {
                Button(action: {
                    locationManager.requestLocation()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        
        let status = locationManager.authorizationStatus
        
        if status == .notDetermined {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .foregroundColor(.blue)
                    .padding(.top, 10)
                
                Text("尋找附近巴士站及抵達時間")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("啟用定位權限，系統會自動探索您目前位置附近的巴士站與即時路線資訊。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                
                Button(action: {
                    locationManager.requestLocation()
                }) {
                    Text("分享目前位置")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(12)
                        .shadow(color: Color.blue.opacity(0.3), radius: 6, x: 0, y: 3)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(14)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } else if status == .denied || status == .restricted {
            VStack(alignment: .center, spacing: 12) {
                Image(systemName: "location.slash.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .foregroundColor(.red)
                    .padding(.top, 10)
                
                Text("定位權限已關閉")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text("如欲使用此定位功能，請至系統設定開啟此應用的定位服務。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                
                Button(action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Text("開啟系統設定")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(14)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } else {
            if locationManager.location == nil || allStops.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(allStops.isEmpty ? "正在載入巴士站數據庫..." : "正在尋找您的位置...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else if nearbyStops.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mappin.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("附近未發現巴士站。")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                ForEach(nearbyStops) { stopModel in
                    let isExpanded = expandedStopIds.contains(stopModel.stopInfo.stop)
                    
                    Section {
                        // Header Row (toggles expansion)
                        Button(action: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                toggleStopExpanded(stopModel.stopInfo.stop)
                            }
                        }) {
                            HStack(alignment: .center) {
                                Image(systemName: "mappin.and.ellipse")
                                    .foregroundColor(.red)
                                    .font(.headline)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stopModel.stopInfo.name_tc)
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.leading)
                                    Text(stopModel.stopInfo.name_en)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 12) {
                                    Text(formatDistance(stopModel.distance))
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.12))
                                        .foregroundColor(.blue)
                                        .cornerRadius(6)
                                    
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        
                        // Route items (if expanded)
                        if isExpanded {
                            if stopModel.routes.isEmpty {
                                Text("目前無即時抵達班次或路線")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(stopModel.routes) { route in
                                    Button(action: {
                                        selectedDirection = route.directionCode == "O" ? "outbound" : "inbound"
                                        searchText = route.route
                                        navigationTitle = route.route.uppercased()
                                        targetScrollStopName = stopModel.stopInfo.name_tc
                                        Task {
                                            await searchRoute(route: route.route)
                                        }
                                    }) {
                                        HStack(alignment: .center, spacing: 12) {
                                            Text(route.route)
                                                .font(.system(.body, design: .rounded))
                                                .fontWeight(.bold)
                                                .foregroundColor(.white)
                                                .frame(width: 64, height: 36)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color(red: 0.65, green: 0.08, blue: 0.12))
                                                )
                                            
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                                    Text("往")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Text(route.destNameTc)
                                                        .font(.system(size: 15, weight: .bold))
                                                        .foregroundColor(.primary)
                                                        .lineLimit(1)
                                                }
                                                Text("to \(route.destNameEn)")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            
                                            Spacer()
                                            
                                            HStack(spacing: 6) {
                                                if let firstEta = route.etas.first, let etaDate = firstEta.etaDate {
                                                    let minutesLeft = max(0, Int(etaDate.timeIntervalSince(currentTime) / 60))
                                                    Text("\(minutesLeft)分")
                                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                                        .foregroundColor(.primary)
                                                } else {
                                                    Text("無即時班次")
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                }
                                                
                                                Image(systemName: "chevron.right")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if let firstEtaDate = route.etas.first?.etaDate,
                                           firstEtaDate.timeIntervalSince(currentTime) > 120 {
                                            Button {
                                                timerTargetDate = firstEtaDate
                                                timerRouteName = route.route
                                                timerDestination = route.destNameTc
                                                showingAddTimerAlert = true
                                            } label: {
                                                Label("提醒", systemImage: "bell.fill")
                                            }
                                            .tint(.blue)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    func toggleStopExpanded(_ stopId: String) {
        if expandedStopIds.contains(stopId) {
            expandedStopIds.remove(stopId)
        } else {
            expandedStopIds.insert(stopId)
        }
    }
    
    func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return String(format: "%.0f 米", distance)
        } else {
            return String(format: "%.1f 公里", distance / 1000)
        }
    }
    
    // MARK: - Network Functions
    
    func loadAllStops() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopResponse.self, from: data)
            
            var newDict: [String: String] = [:]
            var newInfoDict: [String: StopInfo] = [:]
            for stop in response.data {
                newDict[stop.stop] = stop.name_en
                newInfoDict[stop.stop] = stop
            }
            
            await MainActor.run {
                self.allStops = response.data
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
            return Array(temp.prefix(3))
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
    
    func fetchRoutesForStop(stopId: String) async -> [NearbyRouteModel] {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/\(stopId)") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopETAResponse.self, from: data)
            
            var grouped: [String: [StopETAItem]] = [:]
            for item in response.data {
                let key = "\(item.route)-\(item.dir)-\(item.dest_en)"
                grouped[key, default: []].append(item)
            }
            
            var routes: [NearbyRouteModel] = []
            let dateFormatter = ISO8601DateFormatter()
            let now = Date()
            
            for (_, items) in grouped {
                guard let first = items.first else { continue }
                let sortedItems = items.sorted { $0.eta_seq < $1.eta_seq }
                
                var etaInfos: [ETADisplayInfo] = []
                for etaItem in sortedItems {
                    if let etaString = etaItem.eta, let etaDate = dateFormatter.date(from: etaString) {
                        etaInfos.append(ETADisplayInfo(etaDate: etaDate, remark: etaItem.rmk_tc))
                    }
                }
                
                routes.append(NearbyRouteModel(
                    route: first.route,
                    directionCode: first.dir,
                    destNameEn: first.dest_en,
                    destNameTc: first.dest_tc,
                    etas: etaInfos
                ))
            }
            
            return routes.sorted { $0.route.localizedStandardCompare($1.route) == .orderedAscending }
        } catch {
            print("Failed to fetch routes for stop \(stopId): \(error)")
            return []
        }
    }
    
    func searchRoute(route: String) async {
        guard !route.isEmpty else { return }
        
        isLoading = true
        displayData = []
        
        let routeStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(route)/\(selectedDirection)/1")!
        let etaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-eta/\(route)/1")!
        
        do {
            async let (routeStopData, _) = URLSession.shared.data(from: routeStopUrl)
            async let (etaData, _) = URLSession.shared.data(from: etaUrl)
            
            let decoder = JSONDecoder()
            let routeStops = try await decoder.decode(RouteStopResponse.self, from: routeStopData).data
            let allEtas = try await decoder.decode(ETAResponse.self, from: etaData).data
            
            let targetDirectionCode = selectedDirection == "outbound" ? "O" : "I"
            let filteredEtas = allEtas.filter { $0.dir == targetDirectionCode }
            
            let dateFormatter = ISO8601DateFormatter()
            let now = Date()
            var results: [StopDisplayModel] = []
            
            for routeStop in routeStops {
                let stopNameTc: String
                let stopNameEn: String
                if let stopInfo = stopInfoDictionary[routeStop.stop] {
                    stopNameTc = stopInfo.name_tc
                    stopNameEn = stopInfo.name_en
                } else {
                    stopNameTc = stopDictionary[routeStop.stop] ?? "未知車站"
                    stopNameEn = "Unknown Stop"
                }
                
                let seqInt = Int(routeStop.seq) ?? 0
                let stopEtas = filteredEtas.filter { $0.seq == seqInt }
                
                var parsedEtas: [ETADisplayInfo] = []
                for etaItem in stopEtas {
                    if let etaString = etaItem.eta, let etaDate = dateFormatter.date(from: etaString) {
                        parsedEtas.append(ETADisplayInfo(etaDate: etaDate, remark: etaItem.rmk_tc))
                    }
                }
                
                results.append(StopDisplayModel(seq: seqInt, stopNameTc: stopNameTc, stopNameEn: stopNameEn, etas: parsedEtas))
            }
            
            if results.isEmpty {
                systemMessage = "沒有找到路線 \(route) 的 \(selectedDirection == "outbound" ? "去程" : "回程") 班次數據。"
            } else {
                displayData = results
                await MainActor.run {
                    self.navigationTitle = route.uppercased()
                }
            }
            
        } catch {
            systemMessage = "無法加載數據或找不到此路線。"
            print(error)
        }
        
        isLoading = false
    }
    
    @ViewBuilder
    private func activeTimerCard(timer: ActiveTimerModel) -> some View {
        let secondsLeft = max(0, Int(timer.targetAlertDate.timeIntervalSince(currentTime)))
        let minutes = secondsLeft / 60
        let seconds = secondsLeft % 60
        
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(secondsLeft > 0 ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(secondsLeft > 0 && (Int(currentTime.timeIntervalSince1970) % 2 == 0) ? 0.4 : 1.0)
                    
                    Text("倒數提醒中 (巴士抵站前 2 分鐘)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
                
                Spacer()
                
                Button(action: {
                    withAnimation {
                        activeTimer = nil
                        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["KMBTimeAlarm"])
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            
            HStack(spacing: 16) {
                Text(timer.routeName)
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 64, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("往 \(timer.destination)")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text("預計抵達: \(formattedTime(timer.etaDate))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(String(format: "%02d:%02d", minutes, seconds))
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: Color.blue.opacity(0.12), radius: 8, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
    }
    
    func formattedTime(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    func scheduleLocalNotification(routeName: String, destination: String, alertDate: Date) {
        // Cancel existing timer notification
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
}

struct ActiveTimerModel: Identifiable, Equatable {
    let id = UUID()
    let routeName: String
    let destination: String
    let etaDate: Date
    let targetAlertDate: Date
}


