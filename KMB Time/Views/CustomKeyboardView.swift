//
//  CustomKeyboardView.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/4/26.
//

import SwiftUI

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
                                .background(Color.blue)
                                .cornerRadius(6)
                                .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1)
                                .foregroundColor(.white)
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
        .background(
            Color(UIColor.systemGray5)
                .shadow(color: .black.opacity(0.1), radius: 10, y: -5)
                .ignoresSafeArea()
        )
    }
    
    @ViewBuilder
    private func keyboardButton(_ text: String, width: CGFloat, height: CGFloat, action: @escaping () -> Void) -> some View {
        let isValid = validKeys?.contains(text) ?? true
        
        Button(action: action) {
            Text(text)
                .font(.system(size: 22, weight: .regular))
                .frame(width: width, height: height)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(6)
                .shadow(color: Color.black.opacity(isValid ? 0.3 : 0.0), radius: 0, x: 0, y: isValid ? 1 : 0)
                .foregroundColor(isValid ? .primary : Color(UIColor.tertiaryLabel))
        }
        .disabled(!isValid)
    }
    
    @ViewBuilder
    private func actionButton(_ title: String, width: CGFloat, height: CGFloat, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .frame(width: width, height: height)
                .background(color)
                .cornerRadius(6)
                .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1)
                .foregroundColor(.primary)
        }
    }
    
    @ViewBuilder
    private func actionButton(_ icon: Image, width: CGFloat, height: CGFloat, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon
                .font(.system(size: 20))
                .frame(width: width, height: height)
                .background(color)
                .cornerRadius(6)
                .shadow(color: Color.black.opacity(0.3), radius: 0, x: 0, y: 1)
                .foregroundColor(.primary)
        }
    }
}
