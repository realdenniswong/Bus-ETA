/// 檔案用途：顯示首頁搜尋、附近路線、建議路線同即時計時卡。
import SwiftUI

/// `DashboardView` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct DashboardView: View {
    @ObservedObject var locationManager: LocationManager
    @Binding var searchText: String
    @Binding var showCustomKeyboard: Bool
    let activeTimer: ActiveTimerModel?
    let currentTime: Date
    let allStops: [StopInfo]
    let nearbyStops: [NearbyStopModel]
    let allRoutes: [RouteSuggestion]
    let searchSuggestions: [RouteSuggestion]
    let validNextKeys: Set<String>?
    let selectedDirection: String
    let isSearchingNearby: Bool
    
    let onCancelTimer: () -> Void
    let onRequestLocation: () -> Void
    let onRefreshLocationAndNearbyStops: () -> Void
    let onSuggestedRouteSelected: (RouteSuggestion) -> Void
    let onNearbyRouteSelected: (NearbyRouteModel, StopInfo) -> Void
    let onSetNearbyTimer: (NearbyRouteModel, StopInfo) -> Void
    let onSearchRoute: (String, String) -> Void
    let onShowToast: (String) -> Void
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchBarView
                
                List {
                    if let activeTimer {
                        activeTimerCardView(timer: activeTimer)
                    }
                    
                    if !searchText.isEmpty {
                        suggestionsSectionView
                    } else {
                        nearbyDashboardSectionView
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .listSectionSpacing(.custom(16))
                .overlay(alignment: .top) {
                    listTopFade
                }
            }
            .background(themeBackground)
            .simultaneousGesture(
                DragGesture().onChanged { _ in
                    if showCustomKeyboard {
                        dismissKeyboardSafe()
                    }
                }
            )
        }
        .overlay(alignment: .bottom) {
            if showCustomKeyboard {
                customKeyboardOverlay
            }
        }
        .navigationTitle(showCustomKeyboard ? "搜尋路線" : "到站預報")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { dashboardToolbar }
    }
    
    private var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
    
    private var listTopFade: some View {
        LinearGradient(
            colors: [Color(.systemGroupedBackground), Color(.systemGroupedBackground).opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 28)
        .allowsHitTesting(false)
    }
    
    private var searchBarView: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 17, weight: .semibold))
            
            Text(searchText.isEmpty ? "輸入路線 (例如 1A)" : searchText)
                .foregroundStyle(searchText.isEmpty ? .secondary : .primary)
                .font(.system(size: 17, weight: searchText.isEmpty ? .regular : .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, searchText.isEmpty ? 16 : 8)
        .frame(height: 52)
        .liquidGlassSurface(cornerRadius: 24, isInteractive: true)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                showCustomKeyboard = true
            }
        }
    }
    
    private var suggestionsSectionView: some View {
        SuggestionsSectionView(
            suggestions: searchSuggestions,
            allRoutes: allRoutes,
            onSelected: { suggestion, _ in
                onSuggestedRouteSelected(suggestion)
            }
        )
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - timer: 時間或到站時間資料。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func activeTimerCardView(timer: ActiveTimerModel) -> some View {
        ActiveTimerCardView(
            timer: timer,
            currentTime: currentTime,
            onCancel: onCancelTimer
        )
        .id("ActiveTimerCard")
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }
    
    private var nearbyDashboardSectionView: some View {
        NearbyDashboardSectionView(
            locationManager: locationManager,
            allStops: allStops,
            nearbyStops: nearbyStops,
            currentTime: currentTime,
            allRoutes: allRoutes,
            onRequestLocation: onRequestLocation,
            onRouteSelected: onNearbyRouteSelected,
            onSetTimer: onSetNearbyTimer,
            onShowToast: onShowToast
        )
    }
    
    private var customKeyboardOverlay: some View {
        CustomKeyboardView(
            text: $searchText,
            validKeys: validNextKeys,
            onSearch: {
                showCustomKeyboard = false
                onSearchRoute(searchText.uppercased(), selectedDirection)
            },
            onDismiss: { dismissKeyboardSafe() }
        )
        .transition(.offset(y: 300))
    }
    
    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        if !showCustomKeyboard {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSearchingNearby {
                    ProgressView()
                } else {
                    Button(action: onRefreshLocationAndNearbyStops) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .medium))
                    }
                }
            }
        }
    }
    
    /// 停止或收起相關追蹤、活動或流程。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
    private func dismissKeyboardSafe() {
        withAnimation(.spring()) {
            showCustomKeyboard = false
        }
    }
}
/// 擴充 `View`，加入此檔案負責嘅相關功能。
private extension View {
    @ViewBuilder
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - cornerRadius: 搜尋半徑。
    ///   - isInteractive: 控制此流程是否啟用嘅設定。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    func liquidGlassSurface(cornerRadius: CGFloat, isInteractive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if isInteractive {
                self.glassEffect(.regular.tint(.white.opacity(0.18)).interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular.tint(.white.opacity(0.16)), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                )
        }
    }
}

