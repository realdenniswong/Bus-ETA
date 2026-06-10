/// 檔案用途：提供列表 section 邊距對齊 helper。
import SwiftUI

/// 擴充 `View`，加入此檔案負責嘅相關功能。
extension View {
    @ViewBuilder
    /// 判斷指定條件是否成立。
    /// - Parameters:
    ///   - horizontal: 此函式需要嘅輸入資料。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    func alignedListSectionMargins(horizontal length: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.listSectionMargins(.horizontal, length)
        } else {
            self
        }
    }
}
