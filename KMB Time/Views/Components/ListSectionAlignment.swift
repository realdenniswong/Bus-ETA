import SwiftUI

extension View {
    @ViewBuilder
    func alignedListSectionMargins(horizontal length: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.listSectionMargins(.horizontal, length)
        } else {
            self
        }
    }
}
