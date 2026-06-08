//
//  ActiveTimerCardView.swift
//  KMB Time
//
//  Created by Dennis Wong on 6/4/26.
//


import SwiftUI

struct ActiveTimerCardView: View {
    let timer: ActiveTimerModel
    let currentTime: Date
    let onCancel: () -> Void
    
    var body: some View {
        let totalTime = timer.etaDate.timeIntervalSince(timer.startTime)
        let elapsedTime = currentTime.timeIntervalSince(timer.startTime)
        let progress = totalTime > 0 ? min(1.0, max(0.0, elapsedTime / totalTime)) : 1.0
        let secondsLeft = max(0, Int(timer.etaDate.timeIntervalSince(currentTime)))
        
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .opacity(secondsLeft > 0 && (Int(currentTime.timeIntervalSince1970) % 2 == 0) ? 0.3 : 1.0)
                        .animation(.easeInOut(duration: 0.5), value: currentTime)
                    Text("實時追蹤")
                        .font(.caption)
                        .fontWeight(.heavy)
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.15))
                .cornerRadius(10)
                
                Spacer()
                
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .font(.title2)
                }
            }
            .padding([.top, .horizontal], 16)
            
            HStack(alignment: .center) {
                HStack(spacing: 12) {
                    Text(timer.routeName)
                        .font(.system(size: 24, weight: .black))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(KMBRouteTheme.backgroundColor(route: timer.routeName, company: timer.company, allRoutes: []))
                        .foregroundColor(KMBRouteTheme.foregroundColor(route: timer.routeName, company: timer.company, allRoutes: []))
                        .cornerRadius(8)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("往 \(timer.destination)")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Text(timer.stationName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                let minutesLeft = Int(secondsLeft / 60)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(minutesLeft) 分鐘")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(minutesLeft == 0 ? .green : .blue)
                    Text("\(formattedTime(timer.etaDate)) 到達")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            
            GeometryReader { geometry in
                let barWidth = geometry.size.width
                let busPosition = barWidth * CGFloat(progress)
                
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 10)
                    
                    Capsule()
                        .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, busPosition), height: 10)
                        .animation(.linear(duration: 1.0), value: progress)
                    
                    Image(systemName: "bus.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Circle().fill(Color.blue).shadow(radius: 3))
                        .offset(x: max(0, min(busPosition - 17, barWidth - 34)))
                        .animation(.linear(duration: 1.0), value: progress)
                }
            }
            .frame(height: 34)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
            
            HStack {
                VStack(alignment: .leading) {
                    Text("預計到站時間")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formattedTime(timer.etaDate))
                        .font(.headline)
                        .fontWeight(.bold)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("狀態")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    let minutesLeft = max(0, Int(ceil(Double(secondsLeft) / 60.0)))
                    Text(minutesLeft == 0 ? "巴士到站中" : "正常行駛中")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(minutesLeft == 0 ? .green : .secondary)
                }
            }
            .padding(16)
            .background(Color.gray.opacity(0.05))
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.top, 8)
        .padding(.bottom, 8)
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity.combined(with: .scale)))
    }
    
    private func formattedTime(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
