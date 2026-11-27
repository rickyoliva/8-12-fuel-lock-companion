import SwiftUI

@main
struct FuelLockApp: App {
    @StateObject private var fuelService = FuelPriceService()
    @StateObject private var spoofManager = LocationSpoofManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(fuelService)
                .environmentObject(spoofManager)
        }
    }
}
