import UIKit
import UserNotifications

/// Presents the 6-digit pairing PIN over iOS Settings as a local notification
/// so the user can read it while entering the code in Developer Mode settings.
/// Mirrors SideInstaller's `PairingNotification`.
@MainActor
protocol PairingCodeSurface {
    func start()
    func show(code: String)
    func finish(paired: Bool)
}

@MainActor
final class PairingNotification: PairingCodeSurface {

    static let shared = PairingNotification()
    private static let identifier = "com.rickyoliva.fuellock.pairing"

    private var center: UNUserNotificationCenter { .current() }
    private var pairing = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activated() }
        }
    }

    func reset() {
        clear()
    }

    func start() {
        pairing = true
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    func show(code: String) {
        post(
            title: "Pairing Code",
            subtitle: code,
            body: "Enter this code in Settings › Privacy & Security › Developer Mode."
        )
    }

    func finish(paired: Bool) {
        guard pairing else { return }
        pairing = false
        if paired, UIApplication.shared.applicationState != .active {
            post(
                title: "Paired",
                subtitle: "",
                body: "Tap to return to 8/12 Fuel Lock."
            )
        } else {
            clear()
        }
    }

    private func activated() {
        if !pairing { clear() }
    }

    private func post(title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
    }

    private func clear() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }
}
