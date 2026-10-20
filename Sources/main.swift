// Morph: hold Shift while dragging any file and a ring of actions opens at the cursor.
// Drop the file on an action (convert, compress, remove background, GIF, PDF…) and the result is
// saved next to the original. Everything runs on the Mac, offline. Built for Raj Tries Ep 8.
import AppKit
import AVFoundation
import PDFKit
import Quartz
import Vision
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import ServiceManagement

let ACCENT = NSColor(srgbRed: 0.898, green: 0.220, blue: 0.231, alpha: 1)   // #E5383B
let INK = NSColor(srgbRed: 0.10, green: 0.09, blue: 0.09, alpha: 1)
let MUTED = NSColor(srgbRed: 0.48, green: 0.44, blue: 0.43, alpha: 1)

// MARK: - Actions

struct MorphError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

enum Kind { case image, video, audio, pdf, doc, other }

func kind(_ url: URL) -> Kind {
    if url.hasDirectoryPath { return .other }
    guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
    if t.conforms(to: .pdf) { return .pdf }
    if t.conforms(to: .image) { return .image }
    if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
    if t.conforms(to: .audio) { return .audio }
    let docx = UTType("org.openxmlformats.wordprocessingml.document")
    if t.conforms(to: .rtf) || t.conforms(to: .plainText) || t.conforms(to: .html) || t.conforms(to: .rtfd) || (docx != nil && t.conforms(to: docx!)) || url.pathExtension.lowercased() == "doc" || url.pathExtension.lowercased() == "odt" { return .doc }
    return .other
}

/// One wedge in the ring. `run` gets every dropped file and a progress callback, and returns the files it made.
struct Action {
    let title: String
    let symbol: String
    let verb: String   // shown while working: "Compressing"
    let run: ([URL], @escaping (Double) -> Void) throws -> [URL]
}

func actions(for urls: [URL]) -> [Action] {
    let kinds = Set(urls.map(kind))
    let zip = Action(title: "Zip", symbol: "doc.zipper", verb: "Zipping") { u, _ in [try zipFiles(u)] }
    guard kinds.count == 1, let k = kinds.first else { return [zip] }
    let each: (@escaping (URL) throws -> URL) -> ([URL], @escaping (Double) -> Void) throws -> [URL] = { f in
        { us, p in try us.enumerated().map { i, u in let r = try f(u); p(Double(i + 1) / Double(us.count)); return r } }
    }
    switch k {
    case .image:
        return [
            Action(title: "To JPG", symbol: "photo", verb: "Converting", run: each { try convertImage($0, to: .jpeg, ext: "jpg") }),
            Action(title: "To PNG", symbol: "photo.on.rectangle", verb: "Converting", run: each { try convertImage($0, to: .png, ext: "png") }),
            Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", verb: "Compressing", run: each { try compressImage($0) }),
            Action(title: "Remove BG", symbol: "person.crop.rectangle", verb: "Removing background", run: each { try removeBackground($0) }),
            Action(title: "Copy text", symbol: "text.viewfinder", verb: "Reading text") { us, _ in try copyText(us) },
            Action(title: "To PDF", symbol: "doc.richtext", verb: "Making PDF") { us, _ in [try imagesToPDF(us)] },
            zip,
        ]
    case .video:
        return [
            Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", verb: "Compressing", run: { us, p in try us.map { try exportVideo($0, preset: AVAssetExportPresetHEVC1920x1080, type: .mp4, suffix: "-small", ext: "mp4", progress: p) } }),
            Action(title: "To MP4", symbol: "film", verb: "Converting", run: { us, p in try us.map { try exportVideo($0, preset: AVAssetExportPresetHighestQuality, type: .mp4, suffix: "", ext: "mp4", progress: p) } }),
            Action(title: "To GIF", symbol: "sparkles.tv", verb: "Making GIF", run: { us, p in try us.map { try videoToGIF($0, progress: p) } }),
            Action(title: "Audio only", symbol: "waveform", verb: "Extracting audio", run: { us, p in try us.map { try exportVideo($0, preset: AVAssetExportPresetAppleM4A, type: .m4a, suffix: "", ext: "m4a", progress: p) } }),
            zip,
        ]
    case .audio:
        return [
            Action(title: "To M4A", symbol: "music.note", verb: "Converting", run: { us, p in try us.map { try exportVideo($0, preset: AVAssetExportPresetAppleM4A, type: .m4a, suffix: "", ext: "m4a", progress: p) } }),
            Action(title: "To WAV", symbol: "waveform", verb: "Converting", run: each { try audioToWAV($0) }),
            zip,
        ]
    case .pdf:
        var a = [
            Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", verb: "Compressing", run: each { try compressPDF($0) }),
            Action(title: "To images", symbol: "photo.stack", verb: "Exporting pages", run: each { try pdfToImages($0) }),
            Action(title: "Copy text", symbol: "text.viewfinder", verb: "Reading text") { us, _ in try copyText(us) },
        ]
        if urls.count > 1 { a.append(Action(title: "Merge", symbol: "square.stack.3d.down.right", verb: "Merging") { us, _ in [try mergePDFs(us)] }) }
        return a + [zip]
    case .doc:
        return [Action(title: "To PDF", symbol: "doc.richtext", verb: "Making PDF", run: each { try docToPDF($0) }), zip]
    case .other:
        return [zip]
    }
}

/// "photo.jpg", or "photo 2.jpg" if that exists. Never overwrites.
func outURL(_ src: URL, suffix: String = "", ext: String, dir: URL? = nil) -> URL {
    let d = dir ?? src.deletingLastPathComponent(), base = src.deletingPathExtension().lastPathComponent + suffix
    var u = d.appendingPathComponent(base).appendingPathExtension(ext), n = 2
    while FileManager.default.fileExists(atPath: u.path) || u.standardizedFileURL == src.standardizedFileURL {
        u = d.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1
    }
    return u
}

// MARK: images

func loadCG(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw MorphError(msg: "Can't open this image") }
    var o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true]
    if let m = maxPixel { o[kCGImageSourceThumbnailMaxPixelSize] = m } else {
        let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]
        o[kCGImageSourceThumbnailMaxPixelSize] = max(p?[kCGImagePropertyPixelWidth] as? Int ?? 8000, p?[kCGImagePropertyPixelHeight] as? Int ?? 8000)
    }
    guard let img = CGImageSourceCreateThumbnailAtIndex(s, 0, o as CFDictionary) else { throw MorphError(msg: "Can't read this image") }
    return img
}

/// JPEG has no transparency, so transparent pixels become white instead of black.
func flattenOnWhite(_ img: CGImage) -> CGImage {
    guard img.alphaInfo != .none, img.alphaInfo != .noneSkipLast, img.alphaInfo != .noneSkipFirst,
          let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
    ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return ctx.makeImage() ?? img
}

func writeCG(_ img: CGImage, to url: URL, type: UTType, quality: Double? = nil) throws {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw MorphError(msg: "Can't write \(url.pathExtension.uppercased())") }
    var o: [CFString: Any] = [:]
    if let q = quality { o[kCGImageDestinationLossyCompressionQuality] = q }
    CGImageDestinationAddImage(d, type == .jpeg ? flattenOnWhite(img) : img, o as CFDictionary)
    guard CGImageDestinationFinalize(d) else { throw MorphError(msg: "Couldn't save the image") }
}

func convertImage(_ src: URL, to type: UTType, ext: String) throws -> URL {
    let out = outURL(src, ext: ext)
    try writeCG(try loadCG(src), to: out, type: type, quality: type == .jpeg ? 0.92 : nil)
    return out
}

func compressImage(_ src: URL) throws -> URL {   // longest side 2560 px, JPEG at 72%
    let out = outURL(src, suffix: "-small", ext: "jpg")
    try writeCG(try loadCG(src, maxPixel: 2560), to: out, type: .jpeg, quality: 0.72)
    return out
}

func removeBackground(_ src: URL) throws -> URL {
    let img = try loadCG(src)
    let req = VNGenerateForegroundInstanceMaskRequest()
    let h = VNImageRequestHandler(cgImage: img)
    try h.perform([req])
    guard let r = req.results?.first, !r.allInstances.isEmpty else { throw MorphError(msg: "No subject found in this photo") }
    let buf = try r.generateMaskedImage(ofInstances: r.allInstances, from: h, croppedToInstancesExtent: false)
    let ci = CIImage(cvPixelBuffer: buf)
    guard let cg = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw MorphError(msg: "Couldn't cut out the subject") }
    let out = outURL(src, suffix: "-cutout", ext: "png")
    try writeCG(cg, to: out, type: .png)
    return out
}

func imagesToPDF(_ srcs: [URL]) throws -> URL {
    let doc = PDFDocument()
    for s in srcs {
        let cg = try loadCG(s, maxPixel: 3000)
        guard let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))) else { continue }
        doc.insert(page, at: doc.pageCount)
    }
    let out = srcs.count == 1 ? outURL(srcs[0], ext: "pdf") : outURL(srcs[0].deletingLastPathComponent().appendingPathComponent("Images.pdf"), ext: "pdf")
    guard doc.write(to: out) else { throw MorphError(msg: "Couldn't save the PDF") }
    return out
}

// MARK: video & audio

func exportVideo(_ src: URL, preset: String, type: AVFileType, suffix: String, ext: String, progress: @escaping (Double) -> Void) throws -> URL {
    let asset = AVURLAsset(url: src)
    guard let ex = AVAssetExportSession(asset: asset, presetName: preset) else { throw MorphError(msg: "This file can't be exported that way") }
    let out = outURL(src, suffix: suffix, ext: ext)
    ex.outputURL = out; ex.outputFileType = type; ex.shouldOptimizeForNetworkUse = true
    let done = DispatchSemaphore(value: 0)
    ex.exportAsynchronously { done.signal() }
    while done.wait(timeout: .now() + 0.15) == .timedOut { progress(Double(ex.progress)) }
    if ex.status != .completed { throw MorphError(msg: ex.error?.localizedDescription ?? "Export failed") }
    return out
}

func videoToGIF(_ src: URL, progress: @escaping (Double) -> Void) throws -> URL {
    let asset = AVURLAsset(url: src)
    let dur = min(CMTimeGetSeconds(asset.duration), 15), fps = 10.0, n = max(1, Int(dur * fps))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 480, height: 480)
    gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60); gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
    let out = outURL(src, ext: "gif")
    guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, n, nil) else { throw MorphError(msg: "Can't write GIF") }
    CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
    for i in 0..<n {
        let img = try gen.copyCGImage(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600), actualTime: nil)
        CGImageDestinationAddImage(d, img, frameProps)
        progress(Double(i + 1) / Double(n))
    }
    guard CGImageDestinationFinalize(d) else { throw MorphError(msg: "Couldn't save the GIF") }
    return out
}

func audioToWAV(_ src: URL) throws -> URL {
    let inp = try AVAudioFile(forReading: src)
    let fmt = inp.processingFormat, out = outURL(src, ext: "wav")
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: fmt.channelCount,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    let w = try AVAudioFile(forWriting: out, settings: settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1 << 16) else { throw MorphError(msg: "Audio buffer failed") }
    while inp.framePosition < inp.length { try inp.read(into: buf); if buf.frameLength == 0 { break }; try w.write(from: buf) }
    return out
}

// MARK: PDF & documents

func compressPDF(_ src: URL) throws -> URL {
    guard let doc = PDFDocument(url: src) else { throw MorphError(msg: "Can't open this PDF") }
    let out = outURL(src, suffix: "-small", ext: "pdf")
    // Re-encode the PDF's images as JPEG at 150 dpi; text and vectors stay sharp.
    let props: [AnyHashable: Any] = [
        "Domains": ["Applications": true, "Printing": true],
        "FilterType": 1, "Name": "Morph compress",
        "FilterData": ["ColorSettings": ["ImageSettings": [
            "Compression Quality": 0.55, "ImageCompression": "ImageJPEGCompress",
            "ImageScaleSettings": ["ImageResolution": 150, "ImageScaleFactor": 0, "ImageScaleInterpolate": true,
                                   "ImageSizeMax": 0, "ImageSizeMin": 0]]]],
    ]
    var opts: [PDFDocumentWriteOption: Any] = [:]
    if let f = QuartzFilter(properties: props) { opts[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = f }
    guard doc.write(to: out, withOptions: opts) else { throw MorphError(msg: "Couldn't save the PDF") }
    let a = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, b = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    if b >= a { try? FileManager.default.removeItem(at: out); throw MorphError(msg: "This PDF is already as small as it gets") }
    return out
}

func pdfToImages(_ src: URL) throws -> URL {
    guard let doc = PDFDocument(url: src) else { throw MorphError(msg: "Can't open this PDF") }
    let dir = outURL(src, suffix: " pages", ext: "")
    let folder = URL(fileURLWithPath: dir.path.hasSuffix(".") ? String(dir.path.dropLast()) : dir.path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<doc.pageCount {
        guard let p = doc.page(at: i) else { continue }
        let b = p.bounds(for: .mediaBox), sc = 2.0
        let img = p.thumbnail(of: NSSize(width: b.width * sc, height: b.height * sc), for: .mediaBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        try writeCG(cg, to: folder.appendingPathComponent(String(format: "page-%02d.png", i + 1)), type: .png)
    }
    return folder
}

func mergePDFs(_ srcs: [URL]) throws -> URL {
    let doc = PDFDocument()
    for s in srcs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
        guard let d = PDFDocument(url: s) else { continue }
        for i in 0..<d.pageCount { if let p = d.page(at: i) { doc.insert(p, at: doc.pageCount) } }
    }
    let out = outURL(srcs[0].deletingLastPathComponent().appendingPathComponent("Merged.pdf"), ext: "pdf")
    guard doc.write(to: out) else { throw MorphError(msg: "Couldn't save the PDF") }
    return out
}

func docToPDF(_ src: URL) throws -> URL {
    let out = outURL(src, ext: "pdf")
    var err: Error?
    DispatchQueue.main.sync {   // AppKit text layout and printing must run on the main thread
        do {
            let text = try NSAttributedString(url: src, options: [:], documentAttributes: nil)
            let info = NSPrintInfo(dictionary: [NSPrintInfo.AttributeKey.jobSavingURL: out])
            info.jobDisposition = .save
            info.paperSize = NSSize(width: 595, height: 842)   // A4
            info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
            info.isVerticallyCentered = false; info.horizontalPagination = .fit
            let w = info.paperSize.width - info.leftMargin - info.rightMargin
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: w, height: 1))
            tv.textStorage?.setAttributedString(text)
            tv.isVerticallyResizable = true; tv.sizeToFit()
            let op = NSPrintOperation(view: tv, printInfo: info)
            op.showsPrintPanel = false; op.showsProgressPanel = false
            if !op.run() { err = MorphError(msg: "Couldn't print to PDF") }
        } catch { err = error }
    }
    if let e = err { throw e }
    return out
}

// MARK: text from images (OCR)

func recognize(_ img: CGImage) throws -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate; req.usesLanguageCorrection = true; req.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(cgImage: img).perform([req])
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

/// Pulls the text out of a photo, screenshot or PDF, copies it, and saves it as a .txt next to the file.
func copyText(_ srcs: [URL]) throws -> [URL] {
    var parts: [String] = []
    for s in srcs {
        if kind(s) == .pdf, let d = PDFDocument(url: s) {
            for i in 0..<d.pageCount {
                guard let p = d.page(at: i) else { continue }
                if let t = p.string, t.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { parts.append(t); continue }
                let b = p.bounds(for: .mediaBox)   // scanned page: no text layer, so read the picture
                if let cg = p.thumbnail(of: NSSize(width: b.width * 2.5, height: b.height * 2.5), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) { parts.append(try recognize(cg)) }
            }
        } else { parts.append(try recognize(try loadCG(s, maxPixel: 4000))) }
    }
    let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw MorphError(msg: "No text found") }
    DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    let out = outURL(srcs[0], ext: "txt")
    try text.write(to: out, atomically: true, encoding: .utf8)
    return [out]
}

// MARK: zip

func zipFiles(_ srcs: [URL]) throws -> URL {
    let p = Process()
    let out: URL
    if srcs.count == 1 {
        out = outURL(srcs[0], ext: "zip")
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", srcs[0].path, out.path]
    } else {
        let dir = srcs[0].deletingLastPathComponent()
        out = outURL(dir.appendingPathComponent("Archive.zip"), ext: "zip")
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-r", "-q", out.path] + srcs.map { $0.lastPathComponent }
    }
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw MorphError(msg: "Zip failed") }
    return out
}

// MARK: - The ring

final class RingView: NSView {
    var urls: [URL] = [] { didSet { acts = actions(for: urls); hover = nil; needsDisplay = true } }
    private(set) var acts: [Action] = []
    var hover: Int? { didSet { if hover != oldValue { needsDisplay = true; if hover != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) } } } }
    var onDrop: ((Action, [URL]) -> Void)?
    let rIn: CGFloat = 64, rOut: CGFloat = 172

    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    private var c: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var step: CGFloat { 360 / CGFloat(max(1, acts.count)) }

    func index(at p: NSPoint) -> Int? {
        let dx = p.x - c.x, dy = p.y - c.y, r = hypot(dx, dy)
        guard r > rIn - 6, r < rOut + 40, !acts.isEmpty else { return nil }
        var a = 90 - atan2(dy, dx) * 180 / .pi; a = (a.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return min(acts.count - 1, Int(a / step))
    }

    func wedge(_ i: Int, grow: CGFloat = 0) -> NSBezierPath {
        let gap: CGFloat = acts.count > 1 ? 1.6 : 0
        let a0 = 90 - CGFloat(i) * step - gap, a1 = 90 - CGFloat(i + 1) * step + gap
        let p = NSBezierPath()
        if acts.count == 1 {
            p.appendOval(in: NSRect(x: c.x - rOut - grow, y: c.y - rOut - grow, width: 2 * (rOut + grow), height: 2 * (rOut + grow)))
            p.appendOval(in: NSRect(x: c.x - rIn, y: c.y - rIn, width: 2 * rIn, height: 2 * rIn)); p.windingRule = .evenOdd
            return p
        }
        p.appendArc(withCenter: c, radius: rOut + grow, startAngle: a0, endAngle: a1, clockwise: true)
        p.appendArc(withCenter: c, radius: rIn, startAngle: a1, endAngle: a0, clockwise: false)
        p.close()
        return p
    }

    override func draw(_ dirty: NSRect) {
        guard !acts.isEmpty else { return }
        // soft shadow under the whole ring
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.22); sh.shadowBlurRadius = 26; sh.shadowOffset = NSSize(width: 0, height: -8); sh.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - rOut, y: c.y - rOut, width: 2 * rOut, height: 2 * rOut)).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(srgbRed: 0.93, green: 0.90, blue: 0.89, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - rOut, y: c.y - rOut, width: 2 * rOut, height: 2 * rOut)).fill()

        let order = acts.indices.filter { $0 != hover } + (hover.map { [$0] } ?? [])   // hovered wedge last, so it sits on top
        for i in order {
            let a = acts[i], on = hover == i
            (on ? ACCENT : NSColor.white).setFill()
            wedge(i, grow: on ? 8 : 0).fill()
            let mid = (90 - (CGFloat(i) + 0.5) * step) * .pi / 180, rr = (rIn + rOut) / 2 + (on ? 4 : 0)
            let pc = acts.count == 1 ? NSPoint(x: c.x, y: c.y + rr) : NSPoint(x: c.x + cos(mid) * rr, y: c.y + sin(mid) * rr)
            let col = on ? NSColor.white : INK
            if let sym = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.title)?.withSymbolConfiguration(.init(pointSize: 22, weight: .semibold).applying(.init(paletteColors: [col]))) {
                let s = sym.size; sym.draw(in: NSRect(x: pc.x - s.width / 2, y: pc.y + 1, width: s.width, height: s.height))
            }
            let t = NSAttributedString(string: a.title, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .bold), .foregroundColor: col])
            let ts = t.size(); t.draw(at: NSPoint(x: pc.x - ts.width / 2, y: pc.y - ts.height - 2))
        }

        // centre: the file being dragged
        let cr: CGFloat = rIn - 8
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - cr, y: c.y - cr, width: 2 * cr, height: 2 * cr)).fill()
        if let f = urls.first {
            let icon = NSWorkspace.shared.icon(forFile: f.path)
            icon.draw(in: NSRect(x: c.x - 22, y: c.y - 12, width: 44, height: 44))
            let label = urls.count > 1 ? "\(urls.count) files" : (f.pathExtension.isEmpty ? "folder" : f.pathExtension.uppercased())
            let t = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: MUTED])
            let ts = t.size(); t.draw(at: NSPoint(x: c.x - ts.width / 2, y: c.y - 30))
        }
    }

    // dragging
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        hover = index(at: convert(s.draggingLocation, from: nil)); return hover == nil ? [] : .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { hover = nil }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { hover != nil }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let i = hover, i < acts.count else { return false }
        let us = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? urls
        onDrop?(acts[i], us); hover = nil
        return true
    }
}

final class FloatPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false; isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
}

// MARK: - Toast (progress + result)

final class ToastView: NSView {
    var title = "", sub = "", progress: Double? = nil, ok = true, onClick: (() -> Void)?
    override func draw(_ r: NSRect) {
        let b = bounds.insetBy(dx: 14, dy: 14)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.18); sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: -6); sh.set()
        NSColor.white.setFill(); NSBezierPath(roundedRect: b, xRadius: 18, yRadius: 18).fill()
        NSGraphicsContext.restoreGraphicsState()
        let dot = NSRect(x: b.minX + 16, y: b.midY - 15, width: 30, height: 30)
        (ok ? (progress == nil ? NSColor(srgbRed: 0.16, green: 0.65, blue: 0.37, alpha: 1) : ACCENT) : ACCENT).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let glyph = progress != nil ? "…" : (ok ? "✓" : "!")
        let g = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .black), .foregroundColor: NSColor.white])
        let gs = g.size(); g.draw(at: NSPoint(x: dot.midX - gs.width / 2, y: dot.midY - gs.height / 2))
        let x = dot.maxX + 12, w = b.maxX - x - 14
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: INK])
            .draw(with: NSRect(x: x, y: b.midY + 2, width: w, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: MUTED])
            .draw(with: NSRect(x: x, y: b.midY - 17, width: w, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let p = progress {
            let bar = NSRect(x: x, y: b.minY + 9, width: w, height: 4)
            NSColor(srgbRed: 0.93, green: 0.90, blue: 0.89, alpha: 1).setFill(); NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            ACCENT.setFill(); NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(max(0.03, min(1, p))), height: 4), xRadius: 2, yRadius: 2).fill()
        }
    }
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let ring = FloatPanel(size: NSSize(width: 440, height: 440))
    let ringView = RingView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
    let toast = FloatPanel(size: NSSize(width: 360, height: 92))
    let toastView = ToastView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
    var status: NSStatusItem!
    var baseline = NSPasteboard(name: .drag).changeCount
    var shown = false, hideWork: DispatchWorkItem?
    let work = DispatchQueue(label: "morph.work", qos: .userInitiated)

    func applicationDidFinishLaunching(_ n: Notification) {
        ring.contentView = ringView; toast.contentView = toastView
        toast.level = .statusBar; toast.ignoresMouseEvents = false
        ringView.onDrop = { [weak self] a, us in guard let self else { return }; self.dropAt = NSPoint(x: self.ring.frame.midX, y: self.ring.frame.midY); self.hideRing(animated: false); self.perform(a, us) }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Morph")
        let m = NSMenu()
        m.addItem(withTitle: "Hold ⇧ Shift while dragging any file", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())
        let login = m.addItem(withTitle: "Open at login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(withTitle: "Quit Morph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = m

        // Watch for a file drag with Shift held. Polling the drag pasteboard needs no Accessibility permission.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }

        // Test hook: Morph --preview <hover index> file… shows the ring at the screen centre for a screenshot.
        if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--preview" {
            let us = CommandLine.arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }, f = NSScreen.main!.frame
            showRing(Array(us), at: NSPoint(x: f.midX, y: f.midY)); ringView.hover = Int(CommandLine.arguments[2]).flatMap { $0 < 0 ? nil : $0 }
            tickOff = true; return
        }
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showToast("Morph is running", "Hold ⇧ Shift while dragging any file", progress: nil, ok: true, hideAfter: 6)
        }
    }

    var tickOff = false
    func tick() {
        if tickOff { return }
        let down = NSEvent.pressedMouseButtons & 1 != 0, pb = NSPasteboard(name: .drag)
        if !down {
            baseline = pb.changeCount
            if shown && hideWork == nil { let w = DispatchWorkItem { [weak self] in self?.hideRing(animated: true) }; hideWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w) }
            return
        }
        guard !shown, NSEvent.modifierFlags.contains(.shift), pb.changeCount != baseline,
              let us = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !us.isEmpty else { return }
        showRing(us, at: NSEvent.mouseLocation)
    }

    func showRing(_ us: [URL], at p: NSPoint) {
        hideWork?.cancel(); hideWork = nil
        ringView.urls = us
        let s = ring.frame.size, scr = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main!
        var o = NSPoint(x: p.x - s.width / 2, y: p.y - s.height / 2)
        let vf = scr.visibleFrame
        o.x = min(max(o.x, vf.minX - 30), vf.maxX - s.width + 30); o.y = min(max(o.y, vf.minY - 30), vf.maxY - s.height + 30)
        ring.setFrameOrigin(o)
        ring.alphaValue = 0; ring.orderFrontRegardless(); shown = true
        if let l = ringView.layer {
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5); l.position = CGPoint(x: s.width / 2, y: s.height / 2)
            let a = CASpringAnimation(keyPath: "transform.scale"); a.fromValue = 0.55; a.toValue = 1; a.damping = 14; a.stiffness = 260; a.mass = 0.8; a.duration = a.settlingDuration
            l.add(a, forKey: "pop")
        }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.12; ring.animator().alphaValue = 1 }
    }

    func hideRing(animated: Bool) {
        hideWork = nil; guard shown else { return }; shown = false
        if !animated { ring.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.12; ring.animator().alphaValue = 0 }, completionHandler: { [weak self] in if self?.shown == false { self?.ring.orderOut(nil) } })
    }

    func perform(_ a: Action, _ us: [URL]) {
        let name = us.count == 1 ? us[0].lastPathComponent : "\(us.count) files"
        showToast("\(a.verb)…", name, progress: 0, ok: true, hideAfter: nil)
        let t0 = Date()
        work.async { [weak self] in
            do {
                let outs = try a.run(us) { p in DispatchQueue.main.async { self?.toastView.progress = p; self?.toastView.needsDisplay = true } }
                let secs = Date().timeIntervalSince(t0)
                var sub = outs.count == 1 ? outs[0].lastPathComponent : "\(outs.count) files"
                let isText = a.title == "Copy text"
                if isText, let t = try? String(contentsOf: outs[0], encoding: .utf8) {
                    sub = "Copied \(t.split(whereSeparator: \.isWhitespace).count) words · paste anywhere"
                } else if outs.count == 1, us.count == 1, let a0 = try? us[0].resourceValues(forKeys: [.fileSizeKey]).fileSize, let b0 = try? outs[0].resourceValues(forKeys: [.fileSizeKey]).fileSize, a0 > 0 {
                    let f = ByteCountFormatter(); f.countStyle = .file
                    sub = "\(f.string(fromByteCount: Int64(a0))) → \(f.string(fromByteCount: Int64(b0))) · \(outs[0].lastPathComponent)"
                }
                DispatchQueue.main.async {
                    self?.showToast("Done in \(String(format: secs < 10 ? "%.1f" : "%.0f", secs)) s · click to show", sub, progress: nil, ok: true, hideAfter: 4)
                    self?.toastView.onClick = { NSWorkspace.shared.activateFileViewerSelecting(outs); self?.toast.orderOut(nil) }
                    NSSound(named: "Glass")?.play()
                }
            } catch {
                DispatchQueue.main.async { self?.showToast("Couldn't \(a.title.lowercased())", error.localizedDescription, progress: nil, ok: false, hideAfter: 5) }
            }
        }
    }

    var toastHide: DispatchWorkItem?
    var dropAt: NSPoint?   // the result card shows where the file was dropped
    func showToast(_ title: String, _ sub: String, progress: Double?, ok: Bool, hideAfter: Double?) {
        toastHide?.cancel()
        toastView.title = title; toastView.sub = sub; toastView.progress = progress; toastView.ok = ok; toastView.onClick = nil; toastView.needsDisplay = true
        let scr = NSScreen.main ?? NSScreen.screens[0], vf = scr.visibleFrame
        if let p = dropAt {
            let sz = toast.frame.size
            toast.setFrameOrigin(NSPoint(x: min(max(p.x - sz.width / 2, vf.minX), vf.maxX - sz.width), y: min(max(p.y - sz.height / 2 - 40, vf.minY), vf.maxY - sz.height)))
        } else { toast.setFrameOrigin(NSPoint(x: vf.maxX - toast.frame.width - 6, y: vf.maxY - toast.frame.height - 6)) }
        toast.alphaValue = 1; toast.orderFrontRegardless()
        if let h = hideAfter { let w = DispatchWorkItem { [weak self] in self?.toast.orderOut(nil) }; toastHide = w; DispatchQueue.main.asyncAfter(deadline: .now() + h, execute: w) }
    }

    @objc func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister(); item.state = .off }
            else { try SMAppService.mainApp.register(); item.state = .on }
        } catch { showToast("Couldn't change login item", error.localizedDescription, progress: nil, ok: false, hideAfter: 4) }
    }
}

let argv = CommandLine.arguments

// Test hook: Morph --snapshot out.png <hover> file… renders the ring (and a sample toast) to a PNG.
if argv.count > 4, argv[1] == "--snapshot" {
    _ = NSApplication.shared
    let v = RingView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
    v.urls = argv.dropFirst(4).map { URL(fileURLWithPath: $0) }; v.hover = Int(argv[3]).flatMap { $0 < 0 ? nil : $0 }
    let t = ToastView(frame: NSRect(x: 0, y: 0, width: 360, height: 92)); t.title = "Done in 0.3 s · click to show"; t.sub = "4.2 MB → 480 KB · photo-cutout.png"
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 560)); host.wantsLayer = true
    host.layer?.backgroundColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).cgColor
    v.frame.origin = NSPoint(x: 0, y: 120); t.frame.origin = NSPoint(x: 40, y: 10); host.addSubview(v); host.addSubview(t)
    let w = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false); w.contentView = host
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!; host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: argv[2]))
    exit(0)
}

// Test hook: Morph --run "To JPG" file1 file2 … runs one action without the UI and prints what it made.
if argv.count > 3, argv[1] == "--run" {
    let us = argv.dropFirst(3).map { URL(fileURLWithPath: $0) }
    guard let a = actions(for: us).first(where: { $0.title == argv[2] }) else { print("no action \(argv[2]) for these files: \(actions(for: us).map(\.title))"); exit(2) }
    let t0 = Date()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        do { let o = try a.run(us) { _ in }; print(String(format: "%.2fs", Date().timeIntervalSince(t0)), o.map(\.path).joined(separator: "\n")) }
        catch { print("ERROR", error.localizedDescription) }
        done.signal()
    }
    while done.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
