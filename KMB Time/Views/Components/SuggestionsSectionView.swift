//
//  SuggestionsSectionView.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/4/26.
//


import SwiftUI

struct SuggestionsSectionView: View {
    let searchSuggestions: [RouteSuggestion]
    let onSuggestionTapped: (RouteSuggestion) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            if searchSuggestions.isEmpty {
                HStack {
                    Spacer()
                    Text("找不到相關路線")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 30)
                    Spacer()
                }
            } else {
                ForEach(searchSuggestions, id: \.self) { suggestion in
                    HStack(spacing: 16) {
                        Text(suggestion.route)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 52, height: 32)
                            .background(Color(red: 0.65, green: 0.08, blue: 0.12))
                            .cornerRadius(8)
                        
                        HStack(spacing: 6) {
                            Text(suggestion.origin)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                                .layoutPriority(1)
                            
                            Text(suggestion.destination)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        
                        Spacer(minLength: 4)
                        
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                            .layoutPriority(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSuggestionTapped(suggestion)
                    }
                    
                    if suggestion != searchSuggestions.last {
                        Divider()
                            .padding(.leading, 84)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.04), radius: 5, x: 0, y: 2)
    }
}