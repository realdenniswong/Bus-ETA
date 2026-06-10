/// 檔案用途：顯示單一路線站序、方向切換、收藏同重新整理工具列。
import SwiftUI

/// `RouteDetailsView` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct RouteDetailsView: View {
    @Binding var selectedDirection: String
    let routeName: String
    let selectedCompany: String
    let displayData: [StopDisplayModel]
    let highlightedStopId: String?
    let currentTime: Date
    let isLoading: Bool
    let systemMessage: String
    let scrollTriggerId: UUID
    let isFavorite: Bool
    let onDirectionChanged: (String) -> Void
    let onSetTimer: (StopDisplayModel, Date) -> Void
    let onToggleFavorite: () -> Void
    let onRefresh: () -> Void
    
    var body: some View {
        ScrollViewReader { routeProxy in
            ZStack {
                List {
                    directionPickerSection
                    timetableSection
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(8)
                .scrollContentBackground(.hidden)
                .background(themeBackground)
                
                routeDetailOverlay
            }
            .navigationTitle(routeDetailNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { routeDetailToolbar }
            .onChange(of: scrollTriggerId) { _, _ in
                scrollToHighlightedStop(using: routeProxy)
            }
        }
    }
    
    private var routeDetailNavigationTitle: String {
        guard !routeName.isEmpty else { return "路線資料" }
        return "\(routeName.uppercased()) · \(routeDetailCompanyName)"
    }
    
    private var routeDetailCompanyName: String {
        switch selectedCompany {
        case "KMB+CTB":
            return "聯營"
        case BusOperator.ctb.rawValue:
            return "城巴"
        default:
            return "九巴"
        }
    }
    
    private var directionPickerSection: some View {
        Section {
            directionPicker
        }
        .alignedListSectionMargins(horizontal: 16)
    }
    
    private var directionPicker: some View {
        Picker("Direction", selection: $selectedDirection) {
            Text("去程 (Outbound)").tag("outbound")
            Text("回程 (Inbound)").tag("inbound")
        }
        .pickerStyle(.segmented)
        .onChange(of: selectedDirection) { _, newValue in
            onDirectionChanged(newValue)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
    }
    
    private var timetableSection: some View {
        TimetableSectionView(
            displayData: displayData,
            highlightedStopId: highlightedStopId,
            currentTime: currentTime,
            routeCompany: selectedCompany,
            onSetTimer: onSetTimer
        )
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    @ViewBuilder
    private var routeDetailOverlay: some View {
        if isLoading {
            ProgressView("正在獲取數據...")
        } else if displayData.isEmpty && !routeName.isEmpty {
            Text(systemMessage)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        }
    }
    
    @ToolbarContentBuilder
    private var routeDetailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            favoriteToolbarButton
            refreshRouteButton
        }
    }
    
    private var favoriteToolbarButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundColor(isFavorite ? .orange : .primary)
        }
    }
    
    @ViewBuilder
    private var refreshRouteButton: some View {
        if isLoading {
            ProgressView()
        } else {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
            }
        }
    }
    
    private var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - using: 此函式需要嘅輸入資料。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func scrollToHighlightedStop(using proxy: ScrollViewProxy) {
        guard let target = highlightedStopId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
}
