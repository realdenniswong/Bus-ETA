import SwiftUI
import CoreLocation

extension ContentView {
    /// Favourite routes sorted for display: active service first, then nearest stop, direction, and route number.
    var sortedFavorites: [FavoriteRoute] {
        favoritesManager.favoriteRoutes.sorted { first, second in
            let firstStatus = favoriteStatus[first.id]
            let secondStatus = favoriteStatus[second.id]
            
            let firstHasService = !(firstStatus?.etas.isEmpty ?? true)
            let secondHasService = !(secondStatus?.etas.isEmpty ?? true)
            if firstHasService != secondHasService {
                return firstHasService
            }
            
            let firstDistance = firstStatus?.distance ?? .infinity
            let secondDistance = secondStatus?.distance ?? .infinity
            if firstDistance != secondDistance {
                return firstDistance < secondDistance
            }
            
            if first.direction != second.direction {
                return first.direction == "inbound"
            }
            
            return first.route.localizedStandardCompare(second.route) == .orderedAscending
        }
    }
    
    /// Route suggestions matching the current custom-keyboard search text.
    var searchSuggestions: [RouteSuggestion] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.uppercased()
        return Array(allRoutes.filter { $0.route.uppercased().hasPrefix(query) }.prefix(30))
    }
    
    /// Keys that can still produce at least one route suggestion from the current search prefix.
    var validNextKeys: Set<String>? {
        guard !allRoutes.isEmpty else { return nil }
        
        let query = searchText.uppercased()
        if query.isEmpty {
            return Set(allRoutes.compactMap { $0.route.first.map(String.init) })
        }
        
        var nextKeys = Set<String>()
        for suggestion in allRoutes {
            let route = suggestion.route.uppercased()
            if route.hasPrefix(query) && route.count > query.count {
                let index = route.index(route.startIndex, offsetBy: query.count)
                nextKeys.insert(String(route[index]))
            }
        }
        return nextKeys
    }
    
    /// Common grouped background used by dashboard, favourites, and route-detail lists.
    var themeBackground: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
    
    /// Hides the custom route keyboard without clearing the user's current search text.
    func dismissKeyboardSafe() {
        withAnimation(.spring()) {
            showCustomKeyboard = false
        }
    }
    
    /// Shows a short success/status toast at the top of the app.
    ///
    /// - Parameter message: Text to display in the toast.
    func showToast(_ message: String) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        withAnimation(.spring()) {
            self.toastMessage = message
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring()) {
                if self.toastMessage == message {
                    self.toastMessage = nil
                }
            }
        }
    }
    
    /// Builds the visual toast overlay.
    ///
    /// - Parameter message: Text to display in the toast.
    /// - Returns: Toast view used by the top-level `ContentView` overlay.
    func toastView(message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(white: 0.15, opacity: 0.95))
            .cornerRadius(25)
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, 16)
            .zIndex(1)
    }
    
    /// Converts ETA data into the compact text and color used by favourite route rows.
    ///
    /// - Parameter etas: Upcoming ETAs for one route row.
    /// - Returns: Display text plus the semantic color for that text.
    func relativeTimeText(for etas: [ETADisplayInfo]) -> (text: String, color: Color) {
        guard let firstEta = etas.first?.etaDate else {
            return ("沒有班次", .secondary)
        }
        
        let diff = firstEta.timeIntervalSince(currentTime)
        if diff < 60 {
            return ("即將抵達", .red)
        }
        
        return ("\(Int(diff / 60)) 分鐘", .primary)
    }
    
    /// Builds the compact ETA badge shown on favourite rows.
    ///
    /// - Parameter etas: Upcoming ETAs for one favourite route.
    /// - Returns: A badge view containing the first ETA's relative time.
    func etaCountdownView(etas: [ETADisplayInfo]) -> some View {
        let etaInfo = relativeTimeText(for: etas)
        return Text(etaInfo.text)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(etaInfo.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(etaInfo.color.opacity(0.1))
            .cornerRadius(6)
    }
    
    /// Formats a distance for nearby stop and favourite route rows.
    ///
    /// - Parameter distance: Distance in meters.
    /// - Returns: Meters for short distances, kilometres for longer distances.
    func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 1000 {
            return String(format: "%.0f 米", distance)
        }
        return String(format: "%.1f 公里", distance / 1000)
    }
}
