import AppKit

/// A single template image preserves all symbols and values in MenuBarExtra's
/// native label. The cache retains one image, independent of monitoring duration.
@MainActor
enum MenuBarStatusImage {
    private struct Key: Equatable {
        let connected: Bool
        let quota: String?
        let temperature: String?
        let fans: String?
    }
    private struct Metric {
        let symbol: String
        let text: String
        var minimumTextWidth: CGFloat = 0
    }
    private static var lastKey: Key?
    private static var lastImage: NSImage?

    static func make(connected: Bool, quota: String?, temperature: String?, fans: String?) -> NSImage {
        let key = Key(connected: connected, quota: quota, temperature: temperature, fans: fans)
        if key == lastKey, let lastImage { return lastImage }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        func width(_ value: String) -> CGFloat { ceil((value as NSString).size(withAttributes: attributes).width) }
        var metrics = [Metric(symbol: connected ? "lock.shield.fill" : "lock.shield", text: "")]
        if let quota { metrics.append(Metric(symbol: "sparkles", text: quota, minimumTextWidth: width("100%"))) }
        if let temperature { metrics.append(Metric(symbol: "thermometer.medium", text: temperature, minimumTextWidth: width("100°"))) }
        if let fans {
            metrics.append(Metric(symbol: "fanblades", text: fans, minimumTextWidth: width(fans.contains("/") ? "0000/0000" : "0000")))
        }
        let iconWidth: CGFloat = 13, height: CGFloat = 18, gap: CGFloat = 8, textGap: CGFloat = 4
        let sizes = metrics.map { iconWidth + ($0.text.isEmpty ? 0 : textGap + max(width($0.text), $0.minimumTextWidth)) }
        let size = NSSize(width: sizes.reduce(0, +) + CGFloat(metrics.count - 1) * gap, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (index, metric) in metrics.enumerated() {
                let symbol = NSImage(systemSymbolName: metric.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
                if let symbol {
                    let ratio = symbol.size.width / max(1, symbol.size.height)
                    let drawingHeight = min(14, iconWidth / max(0.1, ratio))
                    let drawingWidth = drawingHeight * ratio
                    symbol.draw(in: NSRect(x: x + (iconWidth - drawingWidth) / 2, y: (height - drawingHeight) / 2,
                                           width: drawingWidth, height: drawingHeight))
                }
                if !metric.text.isEmpty {
                    let textSize = (metric.text as NSString).size(withAttributes: attributes)
                    (metric.text as NSString).draw(at: NSPoint(x: x + iconWidth + textGap, y: floor((height - textSize.height) / 2)), withAttributes: attributes)
                }
                x += sizes[index] + gap
            }
            return true
        }
        image.isTemplate = true
        lastKey = key; lastImage = image
        return image
    }
}
