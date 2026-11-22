import SwiftUI

// MARK: - 个性化预览吞吐卡（下载与上传共用同一量程）

struct MonitorNetworkThroughputCard: View {

    let down: Double
    let up: Double
    let downHistory: [Double]
    let upHistory: [Double]
    let timeSpan: TimeInterval
    let slots: Int

    var body: some View {
        // 两系列共用真实最大值量程，保留孤立峰值。
        let peak = MonitorChartScale.niceCeiling(
            max(downHistory.max() ?? 0, upHistory.max() ?? 0))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                stat(title: "下载", icon: "arrow.down", value: down,
                     color: MonitorColors.download)
                stat(title: "上传", icon: "arrow.up", value: up,
                     color: MonitorColors.upload)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("量程 0 – \(MonitorFormat.rate(MonitorFormat.u64(peak)))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)

                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Color.primary.opacity(0.035))

                    ZStack {
                        grid
                            .padding(.horizontal, 1)

                        if downHistory.count > 1 || upHistory.count > 1 {
                            MonitorAreaSparkline(values: downHistory,
                                                 color: MonitorColors.download,
                                                 upperBound: peak,
                                                 slots: slots,
                                                 lineWidth: 1.7)
                            MonitorSparkline(values: upHistory, upperBound: peak, slots: slots)
                                .stroke(MonitorColors.upload,
                                        style: StrokeStyle(lineWidth: 1.7,
                                                           lineCap: .round, lineJoin: .round))
                            endpointDots(peak: peak)
                        } else {
                            Text("等待采样…")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(3)
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.hairlineColor, lineWidth: Theme.Stroke.hairline)
                )

                HStack {
                    Text("\(timeSpan, specifier: "%g") 秒前")
                    Spacer()
                    Text("现在")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(12)
        .glassCard(radius: Theme.Radius.card)
    }

    private func stat(title: String, icon: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10.5))
            }
            .foregroundStyle(color)
            Text(MonitorFormat.rate(MonitorFormat.u64(value)))
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 三档水平网格（虚线），给曲线一个参照
    private var grid: some View {
        GeometryReader { geo in
            Path { path in
                for index in 1...3 {
                    let y = geo.size.height * CGFloat(index) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.primary.opacity(0.06),
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
    }

    /// 右端「当前值」圆点：两条线各一个，压在曲线末端
    private func endpointDots(peak: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                dot(values: downHistory, peak: peak, size: geo.size,
                    color: MonitorColors.download)
                dot(values: upHistory, peak: peak, size: geo.size,
                    color: MonitorColors.upload)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func dot(values: [Double], peak: Double, size: CGSize, color: Color) -> some View {
        if let point = MonitorSparkline.points(values: values, upperBound: peak, slots: slots,
                                              in: CGRect(origin: .zero, size: size)).last {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                .position(x: point.x, y: point.y)
        }
    }
}

/// Y 轴量程：1 / 2 / 5 × 10^n 的「整数刻度」，避免每次采样量程都变
enum MonitorChartScale {
    /// 98 分位峰值：忽略孤立尖峰，又不至于像中位数那样把真实高峰抹平
    static func robustPeak(_ series: [[Double]]) -> Double {
        let all = series.flatMap { $0 }
            .filter { $0.isFinite && $0 > 0 }
            .sorted()
        guard !all.isEmpty else { return 0 }
        let index = min(all.count - 1, Int(Double(all.count - 1) * 0.98))
        return all[index]
    }

    static func niceCeiling(_ raw: Double, floorValue: Double = 1024) -> Double {
        let value = max(raw.isFinite ? raw : 0, floorValue)
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let normalized = value / base
        let nice: Double
        switch normalized {
        case ...1: nice = 1
        case ...2: nice = 2
        case ...5: nice = 5
        default: nice = 10
        }
        return nice * base
    }
}
