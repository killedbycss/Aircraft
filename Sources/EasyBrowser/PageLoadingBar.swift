import SwiftUI


/// Тонкая полоса над страницей: растёт по мере загрузки, доходит до конца и плавно гаснет.
struct PageLoadingBar: View {
    let tab: TabModel
    @State private var visible = false
    @State private var shownProgress: Double = 0
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * shownProgress, height: 2.5)
                .opacity(visible ? 1 : 0)
        }
        .frame(height: 2.5)
        // Полоса загрузки не вылезает за скруглённые углы страницы.
        .padding(.horizontal, AircraftTheme.insetPage ? AircraftTheme.pageCornerRadius * 0.6 : 0)
        .allowsHitTesting(false)
        .onAppear { update(isLoading: tab.isLoading, progress: tab.loadProgress) }
        .onChange(of: tab.isLoading) { _, loading in update(isLoading: loading, progress: tab.loadProgress) }
        .onChange(of: tab.loadProgress) { _, progress in update(isLoading: tab.isLoading, progress: progress) }
    }

    private func update(isLoading: Bool, progress: Double) {
        if isLoading {
            hideTask?.cancel()
            hideTask = nil
            if !visible {
                // Новая загрузка начинается с нуля, без анимации «назад».
                shownProgress = 0
                visible = true
            }
            withAnimation(.easeOut(duration: 0.25)) { shownProgress = max(0.08, progress) }
        } else if visible, hideTask == nil {
            withAnimation(.easeOut(duration: 0.2)) { shownProgress = 1 }
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.25)) { visible = false }
                hideTask = nil
            }
        }
    }
}
