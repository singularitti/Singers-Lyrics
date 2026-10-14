#if os(iOS)
import SwiftUI
import UIKit

@MainActor
private enum MobileIdleTimer {
    private static var owners: Set<UUID> = []

    static func setDisabled(_ isDisabled: Bool, owner: UUID) {
        if isDisabled {
            owners.insert(owner)
        } else {
            owners.remove(owner)
        }

        let shouldDisable = !owners.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != shouldDisable {
            UIApplication.shared.isIdleTimerDisabled = shouldDisable
        }
    }
}

private struct MobileScreenAwakeModifier: ViewModifier {
    let isEnabled: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = UUID()
    @State private var isVisible = false

    private var shouldKeepAwake: Bool {
        isEnabled && isVisible && scenePhase == .active
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updateIdleTimer()
            }
            .onChange(of: shouldKeepAwake) { _, _ in updateIdleTimer() }
            .onDisappear {
                isVisible = false
                updateIdleTimer()
            }
    }

    private func updateIdleTimer() {
        MobileIdleTimer.setDisabled(shouldKeepAwake, owner: owner)
    }
}

extension View {
    func keepsScreenAwake(_ isEnabled: Bool) -> some View {
        modifier(MobileScreenAwakeModifier(isEnabled: isEnabled))
    }
}
#endif
