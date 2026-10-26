import SwiftUI

struct WelcomePermissions: View {
    @Bindable var controller: RecordingController
    let access: WelcomeAccess

    var body: some View {
        VStack(spacing: 12) {
            ForEach(WelcomeAccess.Item.allCases) { permission in
                WelcomeCard(symbol: permission.symbol, title: permission.rawValue, detail: permission.detail) {
                    if access.granted(permission) {
                        Status(text: "Allowed", ready: true)
                    } else {
                        Button("Allow…") {
                            Task { await access.request(permission, controller: controller) }
                        }
                        .accessibilityLabel("Allow \(permission.rawValue)")
                    }
                }
            }
            if access.screen, !controller.screenGrantedAtLaunch {
                HStack {
                    Text("Restart AnyRec to use Screen Recording.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart AnyRec") { Relaunch.now() }
                }
                .padding(.top, 6)
            }
        }
    }
}
