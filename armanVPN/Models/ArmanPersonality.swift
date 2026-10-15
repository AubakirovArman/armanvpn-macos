import Foundation

struct ArmanPersonality {
    let memoryGB: Int

    static var current: Self {
        Self(memoryGB: Int((ProcessInfo.processInfo.physicalMemory + 1_073_741_823) / 1_073_741_824))
    }

    var avatar: String {
        if memoryGB <= 8 { return "ArmanSkeptical" }
        if memoryGB <= 16 { return "ArmanUnimpressed" }
        return "ArmanApproved"
    }

    var verdict: String {
        if memoryGB <= 8 { return "Смело. Очень смело." }
        if memoryGB <= 16 { return "Пойдёт. Но могло быть и 32." }
        if memoryGB <= 32 { return "Вот теперь можно работать." }
        return "Ты сам себе дата-центр."
    }

    var comment: String {
        if memoryGB <= 8 { return "\(memoryGB) ГБ? Орёл смотрит с подозрением. VPN всё равно полетит." }
        if memoryGB <= 16 { return "\(memoryGB) ГБ. В сеть пущу. Апгрейд обсудим за чаем." }
        if memoryGB < 32 { return "\(memoryGB) ГБ. Почти тридцать два. Заходи." }
        if memoryGB == 32 { return "32 ГБ. Арман одобряет. Орёл тоже." }
        return "\(memoryGB) ГБ. Ладно, открывай ещё одну вкладку."
    }

    static let connectedMessage = "Ты в мощной сети Армана."
    static let idleMessage = "Свои люди. Своя сеть."
}
