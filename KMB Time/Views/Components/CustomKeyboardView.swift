/// 檔案用途：提供車號輸入專用鍵盤同按鍵樣式。

import SwiftUI

/// `CustomKeyboardView` 負責支援 KMB Time app 入面對應嘅資料或畫面邏輯。
struct CustomKeyboardView: View {
    @Binding var text: String
    var validKeys: Set<String>?
    var onSearch: () -> Void
    var onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let spacing: CGFloat = 8
                let colWidth = (geo.size.width - (spacing * 6)) / 7
                let keyHeight: CGFloat = 46
                
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        VStack(spacing: spacing) {
                            let numpad = [
                                ["1", "2", "3"],
                                ["4", "5", "6"],
                                ["7", "8", "9"]
                            ]
                            
                            ForEach(numpad, id: \.self) { row in
                                HStack(spacing: spacing) {
                                    ForEach(row, id: \.self) { key in
                                        keyboardButton(key, width: colWidth, height: keyHeight) { text.append(key) }
                                    }
                                }
                            }
                            
                            HStack(spacing: spacing) {
                                Color.clear.frame(width: colWidth, height: keyHeight)
                                keyboardButton("0", width: colWidth, height: keyHeight) { text.append("0") }
                                Color.clear.frame(width: colWidth, height: keyHeight)
                            }
                        }
                        
                        VStack(spacing: spacing) {
                            let alphaRows = [
                                ["A", "B", "C", "D"],
                                ["E", "F", "H", "K"],
                                ["M", "N", "P", "R"],
                                ["S", "T", "W", "X"]
                            ]
                            
                            ForEach(alphaRows, id: \.self) { row in
                                HStack(spacing: spacing) {
                                    ForEach(row, id: \.self) { key in
                                        keyboardButton(key, width: colWidth, height: keyHeight) { text.append(key) }
                                    }
                                }
                            }
                        }
                    }
                    
                    HStack(spacing: spacing) {
                        // 🌟 1. 左下角：取代原本清空，變做「收起鍵盤」掣
                        let dismissWidth = (colWidth * 2) + spacing
                        actionButton(Image(systemName: "keyboard.chevron.compact.down"), width: dismissWidth, height: keyHeight, color: Color(UIColor.systemGray4)) {
                            onDismiss()
                        }
                        
                        // 🌟 2. 中間：「搜尋」掣保持不變
                        let searchWidth = (colWidth * 3) + (spacing * 2)
                        Button(action: onSearch) {
                            Text("搜尋")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: searchWidth, height: keyHeight)
                                .foregroundColor(.white)
                                .keyboardKeySurface(cornerRadius: 10, tint: Color(red: 0.0, green: 0.28, blue: 0.95).opacity(0.72), isInteractive: true)
                        }
                        
                        // 🌟 3. 右下角：「刪除 (Backspace)」掣保持不變
                        let backspaceWidth = (colWidth * 2) + spacing
                        actionButton(Image(systemName: "delete.left"), width: backspaceWidth, height: keyHeight, color: Color(UIColor.systemGray4)) {
                            if !text.isEmpty { text.removeLast() }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .frame(height: 216) // 減去頂部 Toolbar，將整體高度收縮
        }
        .padding(.bottom, 36) // 🌟 增加底部 padding，將成個鍵盤推高，完全避開 iPhone 圓角
        .keyboardPanelSurface()
        .safeAreaPadding(.bottom)
    }
    
    @ViewBuilder
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - text: 畫面顯示文字。
    ///   - width: 版面尺寸或圓角設定。
    ///   - height: 版面尺寸或圓角設定。
    ///   - action: 需要執行嘅 callback 或建立資料嘅 closure。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func keyboardButton(_ text: String, width: CGFloat, height: CGFloat, action: @escaping () -> Void) -> some View {
        let isValid = validKeys?.contains(text) ?? true
        
        Button(action: action) {
            Text(text)
                .font(.system(size: 22, weight: .regular))
                .frame(width: width, height: height)
                .foregroundColor(isValid ? .primary : Color(UIColor.tertiaryLabel))
                .keyboardKeySurface(cornerRadius: 10, tint: .white.opacity(isValid ? 0.18 : 0.08), isInteractive: isValid)
        }
        .disabled(!isValid)
    }
    
    @ViewBuilder
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - title: 畫面顯示文字。
    ///   - width: 版面尺寸或圓角設定。
    ///   - height: 版面尺寸或圓角設定。
    ///   - color: 畫面顏色。
    ///   - action: 需要執行嘅 callback 或建立資料嘅 closure。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func actionButton(_ title: String, width: CGFloat, height: CGFloat, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .frame(width: width, height: height)
                .foregroundColor(.primary)
                .keyboardKeySurface(cornerRadius: 10, tint: .white.opacity(0.14), isInteractive: true)
        }
    }
    
    @ViewBuilder
    /// 執行呢個檔案負責嘅相關功能。
    /// - Parameters:
    ///   - icon: 此函式需要嘅輸入資料。
    ///   - width: 版面尺寸或圓角設定。
    ///   - height: 版面尺寸或圓角設定。
    ///   - color: 畫面顏色。
    ///   - action: 需要執行嘅 callback 或建立資料嘅 closure。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    private func actionButton(_ icon: Image, width: CGFloat, height: CGFloat, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon
                .font(.system(size: 20))
                .frame(width: width, height: height)
                .foregroundColor(.primary)
                .keyboardKeySurface(cornerRadius: 10, tint: .white.opacity(0.14), isInteractive: true)
        }
    }
}

/// 擴充 `View`，加入此檔案負責嘅相關功能。
private extension View {
    @ViewBuilder
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - none: 呢個函式唔需要外部輸入。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    func keyboardPanelSurface() -> some View {
        if #available(iOS 26.0, *) {
            self
                .padding(.horizontal, 6)
                .padding(.top, 8)
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular.tint(.white.opacity(0.16)), in: .rect(cornerRadius: 30))
                        .shadow(color: .black.opacity(0.12), radius: 14, y: -4)
                        .ignoresSafeArea(edges: .bottom)
                )
        } else {
            self.background(
                Color(UIColor.systemGray5)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: -5)
                    .ignoresSafeArea()
            )
        }
    }
    
    @ViewBuilder
    /// 建立用於查找或快取嘅穩定 key。
    /// - Parameters:
    ///   - cornerRadius: 搜尋半徑。
    ///   - tint: 畫面顏色。
    ///   - isInteractive: 控制此流程是否啟用嘅設定。
    /// - Returns: 可供 SwiftUI 顯示嘅畫面內容。
    func keyboardKeySurface(cornerRadius: CGFloat, tint: Color, isInteractive: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if isInteractive {
                self.glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(tint.opacity(0.75), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: Color.black.opacity(isInteractive ? 0.18 : 0.0), radius: 0, x: 0, y: isInteractive ? 1 : 0)
        }
    }
}
