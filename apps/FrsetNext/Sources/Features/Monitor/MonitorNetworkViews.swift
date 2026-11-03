import SwiftUI

// MARK: - 网络页可视化（v183）
//
// 用户反馈（2026-11-02）：
//   「线条十分的差劲，并且不是实时的在更新的。然后它的一个分流的那个图是文本有超出，
//     然后界面是不够美观的，然后很多边界没有考虑到。」
//
// 三件事对应三个改动：
//   ① 折线：逐点 addLine 的折线 → 平滑贝塞尔 + 固定 60 秒窗口 + 网格 + 端点；
//      两条线**共享同一 Y 轴量程**（原来是各归一化各的：148 KB/s 的下载画得比
//      324 KB/s 的上传还高，纯误导）；
//   ② 实时：C 引擎 1s 就更新网络速率，这里用 `NetworkPulse` 以 1s 取点，
//      不走 2s 的通用采样节奏；
//   ③ 分流图：窄窗口下三列流向卡必然挤爆文字 → 换成「比例条 + 逐行明细」，
//      长名字先截断、数值固定宽度、超过 4 个 App 聚合成「其他 N 个」。

// MARK: - 吞吐卡（数值 + 折线）

struct MonitorNetworkThroughputCard: View {

    let down: Double
    let up: Double
    let downHistory: [Double]
    let upHistory: [Double]
    var slots: Int = NetworkPulse.capacity

    var body: some View {
        // 量程按 98 分位取：单个尖峰（计数器抖动/一次性大包）不该把整张图压成平的
        let peak = MonitorChartScale.niceCeiling(
            MonitorChartScale.robustPeak([downHistory, upHistory]))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                stat(title: "下载", icon: "arrow.down", value: down,
                     color: MonitorColors.download)
                stat(title: "上传", icon: "arrow.up", value: up,
                     color: MonitorColors.upload)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.primary.opacity(0.035))

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
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 量程角标：告诉用户这张图的顶在哪，不然「线贴顶」没法判断是多大
                Text(MonitorFormat.rate(MonitorFormat.u64(peak)))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.leading, 6)
                    .padding(.top, 4)
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.hairlineColor, lineWidth: Theme.Stroke.hairline)
            )
            .overlay(alignment: .bottom) {
                HStack {
                    Text("60 秒前").font(.system(size: 9))
                    Spacer()
                    Text("现在").font(.system(size: 9))
                }
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
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
        if let last = values.last {
            let ratio = min(max(last.isFinite ? last : 0, 0) / max(peak, 0.0001), 1)
            let point = CGPoint(x: size.width - 2.5,
                                y: size.height - 8 - CGFloat(ratio) * (size.height - 12))
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

    static func niceCeiling(_ raw: Double) -> Double {
        let floorValue = 1024.0          // 1 KB/s：空载时别把噪声放大成满屏尖峰
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
