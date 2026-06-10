/// 檔案用途：提供 ContentView 衍生狀態、toast 同搜尋建議。
import SwiftUI

/// 擴充 `ContentView`，加入此檔案負責嘅相關功能。
extension ContentView {
    /// Route suggestions matching the current custom-keyboard search text.
    var searchSuggestions: [RouteSuggestion] {
        routeSuggestionCatalog.searchSuggestions(for: searchText)
    }
    
    /// Keys that can still produce at least one route suggestion from the current search prefix.
    var validNextKeys: Set<String>? {
        routeSuggestionCatalog.validNextKeys(for: searchText)
    }
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - message: 畫面顯示文字。
    /// - Returns: 無回傳值；會透過狀態更新或副作用完成工作。
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
    
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - message: 畫面顯示文字。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
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
