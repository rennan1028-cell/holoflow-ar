import SwiftUI

@main
struct HoloFlowApp: App {
    @StateObject private var model = CityModel()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
