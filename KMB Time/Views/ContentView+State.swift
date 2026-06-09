import SwiftUI

extension ContentView {
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
}
