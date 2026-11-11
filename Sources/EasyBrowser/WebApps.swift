import AppKit

/// «Добавить в Dock» (полная версия — этап 8).
@MainActor
enum WebAppMaker {
    static func addActiveTab(of manager: TabManager) { NSSound.beep() }
}

import SwiftUI

struct WebAppsSettingsSection: View {
    var body: some View { EmptyView() }
}
