//
//  ContentView.swift
//  KMB Time
//
//  Created by Dennis Wong on 5/31/26.
//

import SwiftUI

// MARK: - Data Models
struct StopResponse: Codable { let data: [StopInfo] }
struct StopInfo: Codable { let stop: String; let name_tc: String; let name_en: String }

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

struct StopDisplayModel: Identifiable {
    let id = UUID()
    let seq: Int
    let stopName: String
    let etas: [String]
}

// MARK: - User Interface
struct ContentView: View {
    @State private var searchText = ""
    @State private var selectedDirection = "outbound" // Tracks the selected direction
    
    @State private var stopDictionary: [String: String] = [:]
    @State private var displayData: [StopDisplayModel] = []
    
    @State private var isLoading = false
    @State private var systemMessage = "Search for a KMB route (e.g., 1A, 281A)"
    
    var body: some View {
        NavigationStack {
            VStack {
                // 1. Direction Toggle Switch
                Picker("Direction", selection: $selectedDirection) {
                    Text("Outbound (去程)").tag("outbound")
                    Text("Inbound (回程)").tag("inbound")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                // 2. Automatically re-fetch data if the user toggles the switch
                .onChange(of: selectedDirection) { _ in
                    if !searchText.isEmpty {
                        Task {
                            await searchRoute(route: searchText.uppercased())
                        }
                    }
                }
                
                List(displayData) { stop in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(stop.seq). \(stop.stopName)")
                            .font(.headline)
                        
                        if stop.etas.isEmpty {
                            Text("No ETAs available")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(stop.etas, id: \.self) { eta in
                                Text(eta)
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("KMB Tracker")
            .searchable(text: $searchText, prompt: "Enter Route (e.g. 1A)")
            .onSubmit(of: .search) {
                Task {
                    await searchRoute(route: searchText.uppercased())
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Fetching Data...")
                } else if displayData.isEmpty {
                    Text(systemMessage)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .task {
                await loadAllStops()
            }
        }
    }
    
    // MARK: - Network Functions
    
    func loadAllStops() async {
        guard let url = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/stop/") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(StopResponse.self, from: data)
            
            var newDict: [String: String] = [:]
            for stop in response.data {
                // Tip: Swap name_en with name_tc here if you prefer Chinese stop names
                newDict[stop.stop] = stop.name_en
            }
            stopDictionary = newDict
        } catch {
            print("Failed to load stops dictionary: \(error)")
        }
    }
    
    func searchRoute(route: String) async {
        guard !route.isEmpty else { return }
        
        isLoading = true
        displayData = []
        
        // 3. We inject the dynamic selectedDirection into the URL
        let routeStopUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-stop/\(route)/\(selectedDirection)/1")!
        let etaUrl = URL(string: "https://data.etabus.gov.hk/v1/transport/kmb/route-eta/\(route)/1")!
        
        do {
            async let (routeStopData, _) = URLSession.shared.data(from: routeStopUrl)
            async let (etaData, _) = URLSession.shared.data(from: etaUrl)
            
            let decoder = JSONDecoder()
            let routeStops = try await decoder.decode(RouteStopResponse.self, from: routeStopData).data
            let allEtas = try await decoder.decode(ETAResponse.self, from: etaData).data
            
            // 4. Map the full word "outbound"/"inbound" to the letter KMB uses for ETAs ("O"/"I")
            let targetDirectionCode = selectedDirection == "outbound" ? "O" : "I"
            let filteredEtas = allEtas.filter { $0.dir == targetDirectionCode }
            
            let dateFormatter = ISO8601DateFormatter()
            let now = Date()
            var results: [StopDisplayModel] = []
            
            for routeStop in routeStops {
                let stopName = stopDictionary[routeStop.stop] ?? "Unknown Stop"
                
                let seqInt = Int(routeStop.seq) ?? 0
                let stopEtas = filteredEtas.filter { $0.seq == seqInt }
                
                var parsedEtas: [String] = []
                for etaItem in stopEtas {
                    if let etaString = etaItem.eta, let etaDate = dateFormatter.date(from: etaString) {
                        let minutesLeft = max(0, Int(etaDate.timeIntervalSince(now) / 60))
                        let remark = etaItem.rmk_tc ?? ""
                        parsedEtas.append("\(minutesLeft) min (\(remark))")
                    }
                }
                
                results.append(StopDisplayModel(seq: seqInt, stopName: stopName, etas: parsedEtas))
            }
            
            if results.isEmpty {
                systemMessage = "No \(selectedDirection) data found for Route \(route)."
            } else {
                displayData = results
            }
            
        } catch {
            systemMessage = "Route not found or error loading data."
            print(error)
        }
        
        isLoading = false
    }
}
