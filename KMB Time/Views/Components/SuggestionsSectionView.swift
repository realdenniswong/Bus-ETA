//
//  SuggestionsSectionView.swift
//  KMB Time
//

import SwiftUI

struct SuggestionsSectionView: View {
    let searchSuggestions: [RouteSuggestion]
    let onSuggestionTapped: (RouteSuggestion) -> Void
    
    var body: some View {
        Section(header: Text("建議路線")) {
            if searchSuggestions.isEmpty {
                Text("找不到相關路線")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(searchSuggestions) { suggestion in
                    Button(action: {
                        onSuggestionTapped(suggestion)
                    }) {
                        HStack(spacing: 12) {
                            // 🌟 顯示路線與公司標籤
                            VStack(spacing: 2) {
                                Text(suggestion.route)
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .frame(width: 52, height: 32)
                                    .background(suggestion.co == "CTB" ? Color.orange : Color(red: 0.65, green: 0.08, blue: 0.12))
                                    .cornerRadius(8)
                            }
                            
                            // 🌟 顯示目的地與詳細資訊
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("往")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(suggestion.destination)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                                
                                Text("由 \(suggestion.origin) 開出")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
