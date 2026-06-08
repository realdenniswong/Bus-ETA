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
    let routeCompany: String
    
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
                                            let formattedRemark = formattedRemark(for: etaInfo, in: stop.etas)
                                            let minutesLeft = Int(secondsLeft / 60)
                                            if(minutesLeft < -1){
                                                Text("遲到 \(minutesLeft * -1) 分鐘\(formattedRemark)")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    .foregroundColor(Color.red)
                                            }
                                            else if(minutesLeft > 1){
                                                Text("\(minutesLeft) 分鐘\(formattedRemark)")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    .foregroundColor(isHighlighted ? .blue : .primary)
                                            }
                                            else{
                                                Text("即將到站")
                                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                                    .foregroundColor(Color.green)
                                            }
                                            
                                        } else {
                                            Text("-")
                                                .font(.system(size: 15, weight: .semibold, design: .rounded))
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let validEtaDate = stop.etas.first(where: { $0.etaDate?.timeIntervalSince(currentTime) ?? 0 > 120 })?.etaDate {
                                Button {
                                    onSetTimer(stop, validEtaDate)
                                } label: {
                                    Label("設定提示", systemImage: "bell.fill")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func formattedRemark(for etaInfo: ETADisplayInfo, in etas: [ETADisplayInfo]) -> String {
        let parts = [companyRemark(for: etaInfo), normalizedRemark(etaInfo.remark)]
            .compactMap { $0 }
        guard !parts.isEmpty else { return "" }
        return parts.map { "(\($0))" }.joined()
    }
    
    private func companyRemark(for etaInfo: ETADisplayInfo) -> String? {
        guard routeCompany == "KMB+CTB" else { return nil }
        switch etaInfo.companyCode {
        case BusOperator.ctb.rawValue:
            return "城巴"
        default:
            return "九巴"
        }
    }
    
    private func normalizedRemark(_ remark: String?) -> String? {
        guard let remark else { return nil }
        let trimmedRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRemark.isEmpty else { return nil }
        if isLastBusRemark(trimmedRemark) || trimmedRemark == "城巴" || trimmedRemark == "九巴" {
            return nil
        }
        return trimmedRemark
    }
    
    private func isLastBusRemark(_ remark: String) -> Bool {
        remark.contains("最後") || remark.contains("尾班") || remark.localizedCaseInsensitiveContains("last")
    }
}
