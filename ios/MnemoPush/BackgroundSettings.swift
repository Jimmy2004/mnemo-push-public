import Foundation

// Separate defaults preserve compatibility with the original Config JSON.
enum BackgroundSettings {
    static let tiers = ["省电", "均衡", "强力"]
    static var tier: String {
        get { let s = UserDefaults.standard.string(forKey: "keepAliveTier") ?? "省电"; return tiers.contains(s) ? s : "省电" }
        set { UserDefaults.standard.set(newValue, forKey: "keepAliveTier") }
    }
    static var eventMinutes: Int {
        get { max(1, min(1440, UserDefaults.standard.object(forKey: "eventMinutes") as? Int ?? 15)) }
        set { UserDefaults.standard.set(newValue, forKey: "eventMinutes") }
    }
    static var steps: Int {
        get { max(50, min(5000, UserDefaults.standard.object(forKey: "stepThreshold") as? Int ?? 200)) }
        set { UserDefaults.standard.set(newValue, forKey: "stepThreshold") }
    }
    static func description(_ tier: String) -> String {
        switch tier {
        case "均衡": return "低耗电；移动时（约 500 米）唤醒，App 被划掉后也能由系统决定拉起；需要「始终」定位。"
        case "强力": return "耗电较高；按设定间隔同步；来电或其它 App 独占音频时暂停，结束后自动恢复。需要定位及运动权限。"
        default: return "几乎不耗电；同步时间由系统决定，可能数小时一次。"
        }
    }
}
