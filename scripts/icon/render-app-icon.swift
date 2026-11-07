// Renders the macOS AppIcon PNG set from the SVG masters in design/icon/ (iconography.md §6.1, #38).
//
//   swift scripts/icon/render-app-icon.swift                 write Overgrove/Resources/Assets.xcassets/AppIcon.appiconset
//                                                            and copy design/icon/mark.svg into Mark.imageset
//   swift scripts/icon/render-app-icon.swift --check         render to a temporary folder and compare with the
//                                                            committed PNGs (pixel tolerance below); exit 1 if stale
//   swift scripts/icon/render-app-icon.swift --out <dir>     write the set to <dir> instead
//
// Renderer: WebKit, which ships with macOS. Each SVG is drawn into an HTML canvas at the slot's pixel size and read
// back as PNG. WebKit implements the SVG filters the masters use (feGaussianBlur shadows); AppKit's NSImage SVG
// support drops them, so it is not used. No third-party tool is needed (ADR-0006); `rsvg-convert` is an optional
// fallback in scripts/render-app-icon.sh.
//
// Reproducibility: on one machine the output is byte-identical between runs. Across machines (GPU, macOS version)
// anti-aliasing can differ slightly, so --check compares decoded pixels: mean absolute channel difference at most
// `meanTolerance` and no channel off by more than `maxTolerance` (iconography.md §6.1).

import AppKit
import WebKit

struct Slot {
    let file: String
    let points: Int
    let scale: Int
    let source: String
    var pixels: Int { points * scale }
}

/// iconography.md §6.1: 16 and 32 px from the simplified master, 64 px and up from the full one.
let slots: [Slot] = [
    Slot(file: "icon_16x16.png", points: 16, scale: 1, source: "app-icon-small.svg"),
    Slot(file: "icon_16x16@2x.png", points: 16, scale: 2, source: "app-icon-small.svg"),
    Slot(file: "icon_32x32.png", points: 32, scale: 1, source: "app-icon-small.svg"),
    Slot(file: "icon_32x32@2x.png", points: 32, scale: 2, source: "app-icon.svg"),
    Slot(file: "icon_128x128.png", points: 128, scale: 1, source: "app-icon.svg"),
    Slot(file: "icon_128x128@2x.png", points: 128, scale: 2, source: "app-icon.svg"),
    Slot(file: "icon_256x256.png", points: 256, scale: 1, source: "app-icon.svg"),
    Slot(file: "icon_256x256@2x.png", points: 256, scale: 2, source: "app-icon.svg"),
    Slot(file: "icon_512x512.png", points: 512, scale: 1, source: "app-icon.svg"),
    Slot(file: "icon_512x512@2x.png", points: 512, scale: 2, source: "app-icon.svg"),
]

let meanTolerance = 1.0
let maxTolerance = 64

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("design/icon")
let committed = root.appendingPathComponent("Overgrove/Resources/Assets.xcassets/AppIcon.appiconset")
/// The single-color mark for in-app use (S-07), kept as the vector SVG itself (no filters, so AppKit draws it).
let markSource = sources.appendingPathComponent("mark.svg")
let markAsset = root.appendingPathComponent("Overgrove/Resources/Assets.xcassets/Mark.imageset/mark.svg")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
let isCheck = arguments.contains("--check")
arguments.removeAll { $0 == "--check" }
var output = committed
if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
    output = URL(fileURLWithPath: arguments[index + 1], relativeTo: root)
}
if isCheck {
    output = FileManager.default.temporaryDirectory
        .appendingPathComponent("overgrove-appicon-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
}

// MARK: - Contents.json

/// Xcode's own layout for a macOS app icon set, written in a fixed order so the file is stable.
func contentsJSON() -> String {
    let images = slots.map { slot in
        """
            {
              "filename" : "\(slot.file)",
              "idiom" : "mac",
              "scale" : "\(slot.scale)x",
              "size" : "\(slot.points)x\(slot.points)"
            }
        """
    }
    return """
        {
          "images" : [
        \(images.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """
}

// MARK: - Rendering

/// Loads one page with a canvas, then renders each slot through `window.render(svgBase64, size)`.
final class Renderer: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    private var queue = slots
    private let done: () -> Void

    init(done: @escaping () -> Void) {
        self.done = done
    }

    func start() {
        webView.navigationDelegate = self
        let html = """
            <!doctype html><html><body><canvas id="c"></canvas><script>
            window.render = (svg, size) => new Promise((resolve, reject) => {
              const image = new Image();
              image.onload = () => {
                const canvas = document.getElementById('c');
                canvas.width = size; canvas.height = size;
                const context = canvas.getContext('2d');
                context.clearRect(0, 0, size, size);
                context.imageSmoothingQuality = 'high';
                context.drawImage(image, 0, 0, size, size);
                resolve(canvas.toDataURL('image/png'));
              };
              image.onerror = () => reject('the SVG could not be loaded');
              image.src = 'data:image/svg+xml;base64,' + svg;
            });
            </script></body></html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        next()
    }

    private func next() {
        guard !queue.isEmpty else { return done() }
        let slot = queue.removeFirst()
        guard let svg = try? Data(contentsOf: sources.appendingPathComponent(slot.source)) else {
            fail("cannot read design/icon/\(slot.source)")
        }
        webView.callAsyncJavaScript(
            "return await window.render(svg, size)", arguments: ["svg": svg.base64EncodedString(), "size": slot.pixels],
            in: nil, in: .page
        ) { [self] result in
            switch result {
            case .success(let value):
                let prefix = "data:image/png;base64,"
                guard let url = value as? String, url.hasPrefix(prefix),
                    let png = Data(base64Encoded: String(url.dropFirst(prefix.count)))
                else { fail("\(slot.file): the canvas returned no PNG") }
                do {
                    try png.write(to: output.appendingPathComponent(slot.file))
                } catch {
                    fail("\(slot.file): \(error.localizedDescription)")
                }
                next()
            case .failure(let error):
                fail("\(slot.file): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Comparison

/// Straight RGBA bytes of a PNG, drawn into a fixed sRGB buffer so both sides decode the same way.
func pixels(of url: URL) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let data = try? Data(contentsOf: url), let image = NSBitmapImageRep(data: data),
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: image.pixelsWide, height: image.pixelsHigh, bitsPerComponent: 8,
            bytesPerRow: image.pixelsWide * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let cgImage = image.cgImage
    else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh))
    guard let buffer = context.data else { return nil }
    let count = image.pixelsWide * image.pixelsHigh * 4
    return (image.pixelsWide, image.pixelsHigh, Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: count)))
}

func check() -> Bool {
    var isStale = false
    if (try? Data(contentsOf: markSource)) != (try? Data(contentsOf: markAsset)) {
        print("stale  Mark.imageset/mark.svg (copy of design/icon/mark.svg)")
        isStale = true
    }
    if (try? String(contentsOf: committed.appendingPathComponent("Contents.json"), encoding: .utf8)) != contentsJSON() {
        print("stale  Contents.json")
        isStale = true
    }
    for slot in slots {
        guard let fresh = pixels(of: output.appendingPathComponent(slot.file)) else { fail("\(slot.file): no render") }
        guard let old = pixels(of: committed.appendingPathComponent(slot.file)) else {
            print("missing \(slot.file)")
            isStale = true
            continue
        }
        guard fresh.width == slot.pixels, fresh.height == slot.pixels, old.width == fresh.width,
            old.height == fresh.height
        else {
            print("stale  \(slot.file): size \(old.width)x\(old.height), expected \(slot.pixels)x\(slot.pixels)")
            isStale = true
            continue
        }
        var sum = 0
        var largest = 0
        for index in fresh.bytes.indices {
            let difference = abs(Int(fresh.bytes[index]) - Int(old.bytes[index]))
            sum += difference
            largest = max(largest, difference)
        }
        let mean = Double(sum) / Double(fresh.bytes.count)
        let isClose = mean <= meanTolerance && largest <= maxTolerance
        print("\(isClose ? "ok    " : "stale ") \(slot.file): mean \(String(format: "%.3f", mean)), max \(largest)")
        if !isClose { isStale = true }
    }
    return !isStale
}

// MARK: - Main

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(output.path): \(error.localizedDescription)")
}
let application = NSApplication.shared
let renderer = Renderer {
    if isCheck {
        let isFresh = check()
        try? FileManager.default.removeItem(at: output)
        if !isFresh {
            fail("The AppIcon set is stale. Run: scripts/render-app-icon.sh")
        }
        print("ok  AppIcon set")
    } else {
        do {
            try contentsJSON().write(
                to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
            if output == committed {
                try? FileManager.default.removeItem(at: markAsset)
                try FileManager.default.copyItem(at: markSource, to: markAsset)
            }
        } catch {
            fail("\(error.localizedDescription)")
        }
        print("wrote \(slots.count) PNGs and Contents.json to \(output.path)")
    }
    exit(0)
}
renderer.start()
application.run()
