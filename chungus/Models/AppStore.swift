import Foundation
import Observation

@Observable
final class AppStore {
    var apps: [BlockedApp] = [
        BlockedApp(
            id: "instagram",
            name: "INSTAGRAM",
            iconName: "camera.fill",
            platform: "instagram",
            options: [
                BlockingOption(id: "reels", label: "reels", isEnabled: true),
                BlockingOption(id: "msgs", label: "msgs", isEnabled: true),
                BlockingOption(id: "ex-gf", label: "ex-gf", isEnabled: false),
                BlockingOption(id: "explore", label: "explore", isEnabled: false)
            ]
        ),
        BlockedApp(
            id: "shield",
            name: "SHIELD",
            iconName: "shield.fill",
            platform: "facebook",
            options: [
                BlockingOption(id: "alerts", label: "alerts", isEnabled: true),
                BlockingOption(id: "feeds", label: "feeds", isEnabled: false)
            ]
        ),
        BlockedApp(
            id: "kalshi",
            name: "KALSHI",
            iconName: "chart.bar.fill",
            platform: "kalshi",
            options: [
                BlockingOption(id: "trades", label: "trades", isEnabled: true),
                BlockingOption(id: "notifs", label: "notifs", isEnabled: false)
            ]
        ),
        BlockedApp(
            id: "fanduel",
            name: "FANDUEL",
            iconName: "sportscourt.fill",
            platform: "fanduel",
            options: [
                BlockingOption(id: "bets", label: "bets", isEnabled: true),
                BlockingOption(id: "notifs", label: "notifs", isEnabled: false)
            ]
        )
    ]

    func app(for id: String) -> BlockedApp? {
        apps.first { $0.id == id }
    }

    func toggleOption(appId: String, optionId: String) {
        guard let appIndex = apps.firstIndex(where: { $0.id == appId }),
              let optIndex = apps[appIndex].options.firstIndex(where: { $0.id == optionId }) else { return }
        apps[appIndex].options[optIndex].isEnabled.toggle()
    }
}
