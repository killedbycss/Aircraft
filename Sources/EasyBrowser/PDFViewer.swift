import SwiftUI
import PDFKit
import AppKit

/// Встроенный просмотрщик PDF: миниатюры, оглавление, номер страницы, масштаб, поиск (⌘F),
/// сохранение и печать. Последняя страница запоминается.
struct PDFViewerView: View {
    let file: URL
    let tabID: UUID
    let sourceURL: URL?
    @Environment(TabManager.self) private var tabManager: TabManager
    @State private var controller = PDFController()
    @AppStorage("pdfShowsThumbnails") private var showsThumbnails = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if showsThumbnails {
                    PDFSidebar(controller: controller)
                        .frame(width: 168)
                    Divider()
                }
                PDFKitView(controller: controller)
            }
        }
        .onAppear { controller.open(file: file, key: sourceURL?.absoluteString ?? file.path) }
        .onChange(of: file) { _, value in controller.open(file: value, key: sourceURL?.absoluteString ?? value.path) }
        .onDisappear { controller.savePosition() }
        .onReceive(NotificationCenter.default.publisher(for: .pdfFind)) { notification in
            guard (notification.object as? TabManager) === tabManager, tabManager.activeTabID == tabID else { return }
            let query = notification.userInfo?["query"] as? String ?? ""
            if notification.userInfo?["step"] as? Bool == true {
                controller.step(backwards: notification.userInfo?["backwards"] as? Bool == true)
            } else {
                controller.search(query)
            }
            tabManager.findBar.total = controller.matches.count
            tabManager.findBar.current = controller.matches.isEmpty ? 0 : controller.matchIndex + 1
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { showsThumbnails.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("Миниатюры и оглавление")
            Divider().frame(height: 14)
            Button { controller.view?.goToPreviousPage(nil) } label: { Image(systemName: "chevron.up") }
                .help("Предыдущая страница")
            Button { controller.view?.goToNextPage(nil) } label: { Image(systemName: "chevron.down") }
                .help("Следующая страница")
            HStack(spacing: 4) {
                TextField("", value: Binding(
                    get: { controller.pageNumber },
                    set: { controller.go(toPage: $0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .multilineTextAlignment(.center)
                Text("из \(controller.pageCount)").foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.zoom(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Уменьшить")
            Button { controller.zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Увеличить")
            Menu {
                Button("По ширине") { controller.fitWidth() }
                Button("Страница целиком") { controller.fitPage() }
                Button("Реальный размер") { controller.actualSize() }
                Divider()
                Button(controller.isContinuous ? "Постранично" : "Сплошной прокруткой") { controller.toggleContinuous() }
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            Divider().frame(height: 14)
            Button { saveCopy() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Сохранить в Загрузки")
            Button { NSWorkspace.shared.open(file) } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Открыть в Просмотре")
            Button { controller.print() } label: { Image(systemName: "printer") }
                .help("Печать")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func saveCopy() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var target = downloads.appendingPathComponent(file.lastPathComponent)
        var number = 2
        let base = file.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: target.path) {
            target = downloads.appendingPathComponent("\(base) (\(number)).pdf")
            number += 1
        }
        do {
            try FileManager.default.copyItem(at: file, to: target)
            tabManager.showToast("Сохранено в Загрузки", symbol: "arrow.down.circle.fill")
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: target.path)
        } catch {
            NSSound.beep()
        }
    }
}

@MainActor
@Observable
final class PDFController {
    @ObservationIgnored weak var view: PDFView?
    var pageNumber = 1
    var pageCount = 0
    var isContinuous = true
    var outline: PDFOutline?
    @ObservationIgnored var matches: [PDFSelection] = []
    @ObservationIgnored var matchIndex = 0
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var lastQuery = ""
    @ObservationIgnored private var file: URL?

    func attach(_ view: PDFView) {
        self.view = view
        if let file { load(file) }
    }

    func open(file: URL, key: String) {
        guard self.file != file else { return }
        self.file = file
        self.key = key
        if view != nil { load(file) }
    }

    private func load(_ file: URL) {
        guard let view else { return }
        view.document = PDFDocument(url: file)
        pageCount = view.document?.pageCount ?? 0
        outline = view.document?.outlineRoot
        if let saved = Self.positions[key], let page = view.document?.page(at: saved) {
            view.go(to: page)
        }
        updatePage()
    }

    func updatePage() {
        guard let view, let page = view.currentPage, let document = view.document else { return }
        pageNumber = document.index(for: page) + 1
    }

    func go(toPage number: Int) {
        guard let view, let document = view.document, let page = document.page(at: min(max(number, 1), document.pageCount) - 1) else { return }
        view.go(to: page)
    }

    func zoom(_ factor: CGFloat) {
        guard let view else { return }
        view.autoScales = false
        view.scaleFactor = min(max(view.scaleFactor * factor, 0.25), 6)
    }

    func fitWidth() {
        guard let view, let page = view.currentPage else { return }
        let width = page.bounds(for: view.displayBox).width
        view.autoScales = false
        view.scaleFactor = (view.bounds.width - 40) / max(width, 1)
    }

    func fitPage() { view?.autoScales = true }
    func actualSize() {
        view?.autoScales = false
        view?.scaleFactor = 1
    }

    func toggleContinuous() {
        isContinuous.toggle()
        view?.displayMode = isContinuous ? .singlePageContinuous : .singlePage
    }

    func print() {
        guard let view, let document = view.document else { return }
        let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true)
        operation?.runModal(for: view.window ?? NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }

    func search(_ query: String) {
        guard let view, let document = view.document else { return }
        lastQuery = query
        matches = query.isEmpty ? [] : document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        matchIndex = 0
        for match in matches { match.color = NSColor.systemYellow.withAlphaComponent(0.5) }
        view.highlightedSelections = matches.isEmpty ? nil : matches
        showCurrentMatch()
    }

    func step(backwards: Bool) {
        guard !matches.isEmpty else { return }
        matchIndex = backwards ? (matchIndex - 1 + matches.count) % matches.count : (matchIndex + 1) % matches.count
        showCurrentMatch()
    }

    private func showCurrentMatch() {
        guard let view, matches.indices.contains(matchIndex) else {
            view?.setCurrentSelection(nil, animate: false)
            return
        }
        let match = matches[matchIndex]
        view.setCurrentSelection(match, animate: true)
        view.go(to: match)
    }

    func savePosition() {
        guard let view, let page = view.currentPage, let document = view.document, !key.isEmpty else { return }
        var positions = Self.positions
        positions[key] = document.index(for: page)
        if positions.count > 200 { positions = Dictionary(uniqueKeysWithValues: positions.suffix(200).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(positions, forKey: "pdfPositions")
    }

    private static var positions: [String: Int] {
        UserDefaults.standard.dictionary(forKey: "pdfPositions") as? [String: Int] ?? [:]
    }
}

private struct PDFKitView: NSViewRepresentable {
    let controller: PDFController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        controller.attach(view)
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main) { _ in
            MainActor.assumeIsolated { controller.updatePage() }
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Миниатюры страниц и оглавление документа.
private struct PDFSidebar: View {
    let controller: PDFController
    @State private var showsOutline = false

    var body: some View {
        VStack(spacing: 0) {
            if controller.outline?.numberOfChildren ?? 0 > 0 {
                Picker("", selection: $showsOutline) {
                    Text("Страницы").tag(false)
                    Text("Оглавление").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
            }
            if showsOutline, let outline = controller.outline {
                List { OutlineRows(item: outline, controller: controller) }
                    .listStyle(.sidebar)
            } else {
                PDFThumbnails(controller: controller)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

private struct OutlineRows: View {
    let item: PDFOutline
    let controller: PDFController

    var body: some View {
        ForEach(0..<item.numberOfChildren, id: \.self) { index in
            if let child = item.child(at: index) {
                if child.numberOfChildren > 0 {
                    DisclosureGroup {
                        OutlineRows(item: child, controller: controller)
                    } label: { row(child) }
                } else {
                    row(child)
                }
            }
        }
    }

    private func row(_ child: PDFOutline) -> some View {
        Text(child.label ?? "—")
            .lineLimit(2)
            .font(.system(size: 11))
            .contentShape(Rectangle())
            .onTapGesture {
                if let destination = child.destination { controller.view?.go(to: destination) }
            }
    }
}

private struct PDFThumbnails: NSViewRepresentable {
    let controller: PDFController

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = NSSize(width: 120, height: 150)
        view.backgroundColor = .controlBackgroundColor
        view.pdfView = controller.view
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== controller.view { nsView.pdfView = controller.view }
    }
}
