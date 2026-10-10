// FiligrApp — application macOS locale pour ajouter un filigrane texte à des PDF.
// Aucune dépendance : AppKit + Core Graphics + Core Text (fournis par macOS).
// Fonctionne avec les seuls « outils en ligne de commande » d'Apple (Xcode non requis).
// Compilation : voir build.sh

import AppKit
import CoreText

// MARK: - Style du filigrane

struct WatermarkStyle {
    let text: String
    let fontSize: CGFloat
    let color: CGColor
    let angle: CGFloat
    let tiled: Bool
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Moteur PDF

enum WatermarkEngine {

    /// Dessine le filigrane dans un rectangle de page (origine en bas à gauche).
    static func drawWatermark(in ctx: CGContext, rect: CGRect, style: WatermarkStyle) {
        let text = style.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, style.fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent

        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.textMatrix = .identity
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: style.angle * .pi / 180)

        if style.tiled {
            let stepX = width + style.fontSize * 2
            let stepY = height * 3.2
            let half = hypot(rect.width, rect.height) / 2 + max(stepX, stepY)
            var row = 0
            var y = -half
            while y <= half {
                var x = -half + (row % 2 == 0 ? 0 : stepX / 2)
                while x <= half {
                    ctx.textPosition = CGPoint(x: x - width / 2, y: y - height / 2 + descent)
                    CTLineDraw(line, ctx)
                    x += stepX
                }
                y += stepY
                row += 1
            }
        } else {
            ctx.textPosition = CGPoint(x: -width / 2, y: -height / 2 + descent)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }

    /// Taille affichée d'une page, en tenant compte de sa rotation.
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let crop = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        return (rotation == 90 || rotation == 270)
            ? CGSize(width: crop.height, height: crop.width)
            : crop.size
    }

    /// Dessine le contenu original de la page (vectoriel).
    static func drawPageContent(_ page: CGPDFPage, in ctx: CGContext, size: CGSize) {
        let target = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    static func open(_ url: URL) throws -> CGPDFDocument {
        guard let doc = CGPDFDocument(url as CFURL) else {
            throw AppError(message: "fichier illisible ou qui n'est pas un PDF.")
        }
        if doc.isEncrypted && !doc.isUnlocked {
            _ = doc.unlockWithPassword("")
            if !doc.isUnlocked {
                throw AppError(message: "PDF protégé par mot de passe.")
            }
        }
        guard doc.numberOfPages > 0 else { throw AppError(message: "PDF vide.") }
        return doc
    }

    /// Crée un nouveau PDF filigrané (l'original n'est jamais modifié).
    static func apply(to input: URL, output: URL, style: WatermarkStyle) throws {
        let doc = try open(input)
        var defaultBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let info: [CFString: Any] = [kCGPDFContextCreator: "FiligrApp"]
        guard let ctx = CGContext(output as CFURL, mediaBox: &defaultBox, info as CFDictionary) else {
            throw AppError(message: "impossible d'écrire dans ce dossier.")
        }
        for index in 1...doc.numberOfPages {
            guard let page = doc.page(at: index) else { continue }
            let size = displaySize(of: page)
            let mediaBox = CGRect(origin: .zero, size: size)
            let boxData = withUnsafeBytes(of: mediaBox) { Data($0) }
            let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
            ctx.beginPDFPage(pageInfo)
            drawPageContent(page, in: ctx, size: size)
            drawWatermark(in: ctx, rect: mediaBox, style: style)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Image de la première page, sans filigrane (calculée une seule fois par fichier).
    static func renderFirstPage(of url: URL, maxSide: CGFloat = 1400) -> (image: CGImage, size: CGSize)? {
        guard let doc = try? open(url), let page = doc.page(at: 1) else { return nil }
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxSide / max(size.width, size.height)
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = bitmapContext(width: w, height: h) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        drawPageContent(page, in: ctx, size: size)
        guard let image = ctx.makeImage() else { return nil }
        return (image, size)
    }

    /// Superpose le filigrane sur l'image de page en cache (rapide, pour l'aperçu en direct).
    static func composePreview(base: CGImage, pageSize: CGSize, style: WatermarkStyle) -> NSImage? {
        guard let ctx = bitmapContext(width: base.width, height: base.height) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.scaleBy(x: CGFloat(base.width) / pageSize.width, y: CGFloat(base.height) / pageSize.height)
        drawWatermark(in: ctx, rect: CGRect(origin: .zero, size: pageSize), style: style)
        guard let image = ctx.makeImage() else { return nil }
        return NSImage(cgImage: image, size: pageSize)
    }

    static func uniqueOutputURL(in folder: URL, base: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("pdf")
            n += 1
        }
        return candidate
    }
}

// MARK: - Vue qui accepte le glisser-déposer de PDF

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    private func pdfURLs(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !pdfURLs(sender).isEmpty
        onHighlight?(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHighlight?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let urls = pdfURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

// MARK: - Fenêtre principale

final class MainController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let window: NSWindow

    private var files: [URL] = []
    private var cachedURL: URL?
    private var cachedPage: (image: CGImage, size: CGSize)?
    private var working = false

    private let textField = NSTextField(string: "CONFIDENTIEL")
    private let colorWell = NSColorWell()
    private let sizeSlider = NSSlider(value: 64, minValue: 10, maxValue: 200, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 0.25, minValue: 0.05, maxValue: 1, target: nil, action: nil)
    private let angleSlider = NSSlider(value: 45, minValue: -90, maxValue: 90, target: nil, action: nil)
    private let sizeValue = NSTextField(labelWithString: "")
    private let opacityValue = NSTextField(labelWithString: "")
    private let angleValue = NSTextField(labelWithString: "")
    private let layoutControl = NSSegmentedControl(labels: ["Centré", "Mosaïque"],
                                                   trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let addButton = NSButton(title: "Ajouter…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Retirer", target: nil, action: nil)
    private let clearButton = NSButton(title: "Tout vider", target: nil, action: nil)
    private let nextToOriginal = NSButton(checkboxWithTitle: "Enregistrer à côté des originaux",
                                          target: nil, action: nil)
    private let applyButton = NSButton(title: "Appliquer le filigrane", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let previewBox = NSBox()
    private let previewView = NSImageView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "FiligrApp"
        window.minSize = NSSize(width: 900, height: 720)
        window.isReleasedWhenClosed = false
        buildUI()
        updateValueLabels()
        refreshPreview()
        updateButtons()
        window.center()
    }

    // MARK: Construction de l'interface

    private func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func valueRow(_ title: String, _ trailing: NSView) -> NSStackView {
        let row = NSStackView(views: [NSTextField(labelWithString: title), trailing])
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        return row
    }

    private func buildUI() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 1040, height: 760))
        root.onDrop = { [weak self] urls in self?.add(urls) }
        root.onHighlight = { [weak self] on in self?.setDropHighlight(on) }
        window.contentView = root

        // Réglages
        textField.placeholderString = "Ex. CONFIDENTIEL"
        textField.delegate = self

        NSColorPanel.shared.showsAlpha = false
        colorWell.color = NSColor(srgbRed: 0.86, green: 0.12, blue: 0.12, alpha: 1)
        colorWell.target = self
        colorWell.action = #selector(settingsChanged(_:))
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        for slider in [sizeSlider, opacitySlider, angleSlider] {
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(settingsChanged(_:))
        }
        for label in [sizeValue, opacityValue, angleValue] {
            label.textColor = .secondaryLabelColor
            label.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.alignment = .right
        }

        layoutControl.selectedSegment = 0
        layoutControl.target = self
        layoutControl.action = #selector(settingsChanged(_:))

        // Liste des fichiers
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.width = 260
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        addButton.target = self
        addButton.action = #selector(chooseFiles)
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        clearButton.target = self
        clearButton.action = #selector(clearAll)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttonsRow = NSStackView(views: [addButton, removeButton, spacer, clearButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.distribution = .fill
        for b in [addButton, removeButton, clearButton] {
            b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }

        nextToOriginal.state = .on

        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .large
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(exportAll)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true
        statusLabel.preferredMaxLayoutWidth = 284

        let sizeRow = valueRow("Taille", sizeValue)
        let opacityRow = valueRow("Opacité", opacityValue)
        let angleRow = valueRow("Angle", angleValue)

        let left = NSStackView(views: [
            header("Texte"), textField,
            header("Apparence"), valueRow("Couleur", colorWell),
            sizeRow, sizeSlider, opacityRow, opacitySlider, angleRow, angleSlider,
            layoutControl,
            header("Documents"), tableScroll, buttonsRow,
            nextToOriginal, applyButton, progress, statusLabel
        ])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        left.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        left.setCustomSpacing(20, after: textField)
        left.setCustomSpacing(2, after: sizeRow)
        left.setCustomSpacing(2, after: opacityRow)
        left.setCustomSpacing(2, after: angleRow)
        left.setCustomSpacing(20, after: layoutControl)
        left.setCustomSpacing(16, after: buttonsRow)
        left.setCustomSpacing(14, after: nextToOriginal)
        left.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(left)

        let fullWidth: [NSView] = [textField, sizeRow, sizeSlider, opacityRow, opacitySlider,
                                   angleRow, angleSlider, layoutControl, tableScroll, buttonsRow,
                                   applyButton, statusLabel, left.arrangedSubviews[3]]
        for v in fullWidth {
            v.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -36).isActive = true
        }

        // Séparateur vertical
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        // Zone d'aperçu
        previewBox.boxType = .custom
        previewBox.titlePosition = .noTitle
        previewBox.fillColor = .underPageBackgroundColor
        previewBox.borderColor = .controlAccentColor
        previewBox.borderWidth = 0
        previewBox.cornerRadius = 0
        previewBox.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(previewBox)

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        previewView.shadow = shadow
        previewView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(previewView)

        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = NSFont.systemFont(ofSize: 17)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(placeholder)

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 320),

            separator.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            previewBox.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            previewBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewBox.topAnchor.constraint(equalTo: root.topAnchor),
            previewBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            previewView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 28),
            previewView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -28),
            previewView.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 28),
            previewView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -28),

            placeholder.centerXAnchor.constraint(equalTo: previewBox.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: previewBox.widthAnchor, constant: -40)
        ])
    }

    // MARK: Réglages et aperçu

    private func currentStyle() -> WatermarkStyle {
        let base = colorWell.color.usingColorSpace(.sRGB) ?? NSColor.red
        return WatermarkStyle(
            text: textField.stringValue,
            fontSize: CGFloat(sizeSlider.doubleValue),
            color: base.withAlphaComponent(CGFloat(opacitySlider.doubleValue)).cgColor,
            angle: CGFloat(angleSlider.doubleValue),
            tiled: layoutControl.selectedSegment == 1
        )
    }

    private func updateValueLabels() {
        sizeValue.stringValue = "\(Int(sizeSlider.doubleValue.rounded())) pt"
        opacityValue.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded())) %"
        angleValue.stringValue = "\(Int(angleSlider.doubleValue.rounded()))°"
    }

    @objc private func settingsChanged(_ sender: Any?) {
        updateValueLabels()
        updatePreviewImage()
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        settingsChanged(nil)
    }

    private var currentURL: URL? {
        let row = table.selectedRow
        if row >= 0 && row < files.count { return files[row] }
        return files.first
    }

    private func refreshPreview() {
        guard let url = currentURL else {
            cachedURL = nil
            cachedPage = nil
            updatePreviewImage()
            return
        }
        if url != cachedURL {
            cachedURL = url
            cachedPage = WatermarkEngine.renderFirstPage(of: url)
        }
        updatePreviewImage()
    }

    private func updatePreviewImage() {
        if let page = cachedPage {
            previewView.image = WatermarkEngine.composePreview(base: page.image, pageSize: page.size,
                                                               style: currentStyle())
            placeholder.isHidden = true
        } else {
            previewView.image = nil
            placeholder.isHidden = false
            placeholder.stringValue = files.isEmpty
                ? "Déposez vos PDF ici\nou cliquez sur « Ajouter… »"
                : "Aperçu indisponible pour ce fichier"
        }
    }

    private func setDropHighlight(_ on: Bool) {
        previewBox.borderWidth = on ? 3 : 0
    }

    private func updateButtons() {
        let hasText = !textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        addButton.isEnabled = !working
        removeButton.isEnabled = !working && table.selectedRow >= 0
        clearButton.isEnabled = !working && !files.isEmpty
        applyButton.isEnabled = !working && hasText && !files.isEmpty
        applyButton.title = files.count > 1 ? "Appliquer à \(files.count) PDF" : "Appliquer le filigrane"
    }

    // MARK: Liste des fichiers

    func numberOfRows(in tableView: NSTableView) -> Int {
        files.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = id
            label.lineBreakMode = .byTruncatingMiddle
        }
        label.stringValue = files[row].lastPathComponent
        label.toolTip = files[row].path
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshPreview()
        updateButtons()
    }

    func add(_ urls: [URL]) {
        let pdfs = urls
            .map { $0.standardizedFileURL }
            .filter { $0.pathExtension.lowercased() == "pdf" }
        var added = false
        for url in pdfs where !files.contains(url) {
            files.append(url)
            added = true
        }
        guard added else { return }
        table.reloadData()
        if table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        statusLabel.stringValue = ""
        refreshPreview()
        updateButtons()
    }

    @objc func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["pdf"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Ajouter"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard row >= 0, row < files.count else { return }
        files.remove(at: row)
        table.reloadData()
        if !files.isEmpty {
            table.selectRowIndexes(IndexSet(integer: min(row, files.count - 1)), byExtendingSelection: false)
        }
        refreshPreview()
        updateButtons()
    }

    @objc private func clearAll() {
        files.removeAll()
        table.reloadData()
        statusLabel.stringValue = ""
        refreshPreview()
        updateButtons()
    }

    // MARK: Export

    @objc private func exportAll() {
        guard !working, !files.isEmpty else { return }
        var destination: URL? = nil
        if nextToOriginal.state != .on {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Enregistrer ici"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }

        let style = currentStyle()
        let inputs = files
        let target = destination
        working = true
        updateButtons()
        progress.startAnimation(nil)
        statusLabel.stringValue = "Traitement en cours…"

        DispatchQueue.global(qos: .userInitiated).async {
            var outputs: [URL] = []
            var errors: [String] = []
            for input in inputs {
                let folder = target ?? input.deletingLastPathComponent()
                let base = input.deletingPathExtension().lastPathComponent + " - filigrane"
                let output = WatermarkEngine.uniqueOutputURL(in: folder, base: base)
                do {
                    try WatermarkEngine.apply(to: input, output: output, style: style)
                    outputs.append(output)
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    errors.append("• \(input.lastPathComponent) : \(error.localizedDescription)")
                }
            }
            let finalOutputs = outputs
            let finalErrors = errors
            DispatchQueue.main.async { [weak self] in
                self?.finishExport(outputs: finalOutputs, errors: finalErrors)
            }
        }
    }

    private func finishExport(outputs: [URL], errors: [String]) {
        working = false
        progress.stopAnimation(nil)
        updateButtons()
        var lines: [String] = []
        if !outputs.isEmpty {
            lines.append("✓ \(outputs.count) PDF créé\(outputs.count > 1 ? "s" : "").")
        }
        lines.append(contentsOf: errors)
        statusLabel.stringValue = lines.joined(separator: "\n")
        if !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let c = MainController()
        controller = c
        buildMenu(target: c)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// PDF déposés sur l'icône de l'appli ou ouverts avec « Ouvrir avec ».
    func application(_ application: NSApplication, open urls: [URL]) {
        controller?.add(urls)
    }

    private func buildMenu(target: MainController) {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Masquer FiligrApp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quitter FiligrApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "Fichier")
        let addItem = fileMenu.addItem(withTitle: "Ajouter des PDF…", action: #selector(MainController.chooseFiles), keyEquivalent: "o")
        addItem.target = target
        fileMenu.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Édition")
        editMenu.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

@main
enum FiligrAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}
