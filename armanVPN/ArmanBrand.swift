import AppKit
import SwiftUI

enum ArmanBrand {
    static let gold = Color(red: 0.91, green: 0.70, blue: 0.39)
    static let night = Color(red: 0.055, green: 0.066, blue: 0.086)
    static let panel = Color(red: 0.087, green: 0.102, blue: 0.13)
    static let cyan = Color(red: 0.35, green: 0.81, blue: 0.93)
}

struct ArmanAvatar: View {
    let personality: ArmanPersonality
    var size: CGFloat = 84

    var body: some View {
        Group {
            if NSImage(named: personality.avatar) != nil {
                Image(personality.avatar).resizable().scaledToFit()
            } else {
                Image("ArmanPoster").resizable().scaledToFill()
                    .frame(width: size * 2.3, height: size * 2.9)
                    .offset(x: size * 0.02, y: size * 0.48)
            }
        }
        .frame(width: size, height: size)
        .background(RadialGradient(colors: [ArmanBrand.gold.opacity(0.16), .clear], center: .center,
                                   startRadius: 0, endRadius: size * 0.7))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityLabel("Реакция Армана: \(personality.verdict)")
    }
}

struct ArmanMemoryCard: View {
    var personality = ArmanPersonality.current
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 12 : 16) {
            ArmanAvatar(personality: personality, size: compact ? 70 : 92)
            VStack(alignment: .leading, spacing: 6) {
                Text("ТВОЙ MAC · \(personality.memoryGB) ГБ")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(ArmanBrand.gold)
                Text(personality.verdict).font(.system(size: compact ? 14 : 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(personality.comment).font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(.white.opacity(0.56)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 16)
        .background(ArmanBrand.gold.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ArmanBrand.gold.opacity(0.16)))
    }
}
