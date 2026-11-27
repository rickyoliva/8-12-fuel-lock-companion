import SwiftUI

@main
struct FuelLockApp: App {
    @StateObject private var fuelService = FuelPriceService()
    @StateObject private var spoofManager = LocationSpoofManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    ContentView()
                } else {
                    OnboardingView {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            hasCompletedOnboarding = true
                        }
                    }
                }
            }
            .environmentObject(fuelService)
            .environmentObject(spoofManager)
            .onOpenURL { url in
                spoofManager.handleIncomingURL(url)
            }
        }
    }
}
