//
//  TimetableSectionView.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/4/26.
//

import SwiftUI

struct TimetableSectionView: View {
    let displayData: [StopDisplayModel]
    let highlightedStopId: String?
    let currentTime: Date
    
    // 🌟 新增 Callback: 當用家 Swipe 並設定 Timer 時觸發
    let onSetTimer: (StopDisplayModel, Date) -> Void
    
    var body: some View {
        Group {
            if !displayData.isEmpty {
                Section {
                    ForEach(Array(displayData.enumerated()), id: \.element.id) { index, stop in
                        let isHighlighted = stop.id == highlightedStopId
                        
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(isHighlighted ? Color.blue : Color(red: 0.65, green: 0.08, blue: 0.12))
                                    .frame(width: isHighlighted ? 16 : 12, height: isHighlighted ? 16 : 12)
                                    .padding(.top, isHighlighted ? 4 : 6)
                                
                                if index < displayData.count - 1 {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(width: 2)
                                        .frame(maxHeight: .infinity)
                                }
                            }
                            .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(stop.seq). \(stop.stopNameTc)")
                                        .font(isHighlighted ? .title3 : .headline)
                                        .fontWeight(isHighlighted ? .black : .semibold)
                                        .foregroundColor(isHighlighted ? .blue : .primary)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(0..<3, id: \.self) { etaIndex in
                                        let etaInfo = etaIndex < stop.etas.count ? stop.etas[etaIndex] : nil
                                        if let etaInfo = etaInfo, let etaDate = etaInfo.etaDate {
                                            let secondsLeft = etaDate.timeIntervalSince(currentTime)
                                            let remark = etaInfo.remark ?? ""
                                            let formattedRemark = remark.isEmpty ? "" : " (\(remark))"
                                            let minutesLeft = Int(secondsLeft / 60)
                                            if(minutesLeft < 0){
                                                Text("遲到 \(minutesLeft * -1) 分鐘\(formattedRemark)")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    .foregroundColor(Color.red)
                                            }
                                            else if(minutesLeft == 0){
                                                Text("即將到站")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    .foregroundColor(Color.green)
                                            }
                                            else{
                                                Text("\(minutesLeft) 分鐘\(formattedRemark)")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    // 🌟 呢度更新咗：如果是 Highlighted 車站，字體變藍色
                                                    .foregroundColor(isHighlighted ? .blue : .primary)
                                            }
                                            
                                        } else {
                                            Text("-")
                                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                // 🌟 呢度都更新埋：連住個 "-" 都一齊變藍色保持統一
                                                .foregroundColor(isHighlighted ? .blue : .primary)
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, index < displayData.count - 1 ? 20 : 0)
                            
                            Spacer(minLength: 0)
                        }
                        .padding(.top, index == 0 ? 16 : 0)
                        .padding(.bottom, index == displayData.count - 1 ? 16 : 0)
                        .id(stop.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                        // 🌟 加入向左滑動新增 Timer 嘅選項
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // 尋找第一個有效且大於 2 分鐘嘅 ETA
                            if let validEtaDate = stop.etas.first(where: { $0.etaDate?.timeIntervalSince(currentTime) ?? 0 > 120 })?.etaDate {
                                Button {
                                    onSetTimer(stop, validEtaDate)
                                } label: {
                                    Label("提醒", systemImage: "bell.fill")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
        }
    }
}
