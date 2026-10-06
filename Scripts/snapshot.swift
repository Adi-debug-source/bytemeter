// Renders a dashboard page in WebKit, the engine Safari uses, and saves the
// whole page as a PNG for the README images: 1400 CSS pixels wide, at twice
// that in pixels, in sRGB. It needs no browser and no browser profile, and
// the page is a local file that fetches nothing. Not part of the app: SwiftPM
// does not build anything in Scripts.
//
//   swift Scripts/snapshot.swift DASHBOARD.html PAGE.png
//       Renders the page, and prints where each section sits in PAGE.png,
//       in pixels. The crops in MAINTENANCE.md are measured from those.
//
//   swift Scripts/snapshot.swift --strip FILE.png...
//       Rewrites each PNG keeping only the chunks the image needs (IHDR,
//       PLTE, tRNS, IDAT, IEND), so no colour profile, EXIF, text, date or
//       physical size travels with it, and marks it sRGB, which the snapshot
//       is. Run it on the crops sips writes: sips swaps the sRGB mark for
//       gAMA, cHRM and EXIF chunks but leaves the pixels as they were.

import AppKit
import WebKit

let cssWidth = 1400
let scale = 2

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
    exit(1)
}

// MARK: - Strip

func strip(_ path: String, quiet: Bool = false) {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard data.count > 8, Array(data.prefix(8)) == signature else { fail("\(path) is not a PNG") }
    let keep: Set<String> = ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"]
    // The standard sRGB chunk, perceptual intent: length 1, "sRGB", 0, CRC.
    let sRGBChunk: [UInt8] = [0, 0, 0, 1, 0x73, 0x52, 0x47, 0x42, 0, 0xAE, 0xCE, 0x1C, 0xE9]
    var out = Data(signature)
    var dropped: [String] = []
    var index = 8
    while index + 12 <= data.count {
        let length = data[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
        let end = index + 12 + length
        guard end <= data.count else { fail("\(path) is cut short") }
        let kind = String(decoding: data[index + 4..<index + 8], as: UTF8.self)
        if keep.contains(kind) { out.append(data[index..<end]) } else if kind != "sRGB" { dropped.append(kind) }
        if kind == "IHDR" { out.append(contentsOf: sRGBChunk) }
        index = end
        if kind == "IEND" { break }
    }
    do { try out.write(to: URL(fileURLWithPath: path)) } catch { fail("cannot write \(path): \(error)") }
    if !quiet { print("\(path): dropped \(dropped.isEmpty ? "nothing" : dropped.joined(separator: ", "))") }
}

// MARK: - Render

/// Copies the snapshot into a plain sRGB bitmap with no alpha, then writes it
/// as a PNG and strips it. Refuses anything but exactly twice the CSS size,
/// so a Mac without a Retina screen cannot quietly make blurry images.
func writePNG(_ image: NSImage, to path: String, width: Int, height: Int) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let source = rep.cgImage else {
        fail("the snapshot could not be read")
    }
    guard source.width == width, source.height == height else {
        fail("the snapshot is \(source.width) by \(source.height) pixels, not \(width) by \(height). "
           + "It is taken at the screen's scale, so it needs a Retina screen.")
    }
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        fail("could not make an sRGB bitmap")
    }
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let flat = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            "public.png" as CFString, 1, nil) else {
        fail("could not start \(path)")
    }
    CGImageDestinationAddImage(destination, flat, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(path)") }
    strip(path, quiet: true)
}

/// Each part of the page, as rows of text: top, bottom, left and right in
/// pixels of the saved PNG.
let measure = """
(() => {
  const rows = [];
  const add = (name, el) => {
    if (!el) return;
    const b = el.getBoundingClientRect(), k = \(scale);
    rows.push(name.padEnd(30) + ' top ' + Math.round((b.top + scrollY) * k) + '  bottom ' + Math.round((b.bottom + scrollY) * k)
      + '  left ' + Math.round(b.left * k) + '  right ' + Math.round(b.right * k));
  };
  add('body', document.body);
  add('masthead', document.querySelector('.masthead'));
  add('hero', document.querySelector('.hero'));
  for (const s of document.querySelectorAll('section.panel')) {
    const h = s.querySelector('h2');
    add('panel: ' + (h ? h.textContent.trim() : 'untitled'), s);
  }
  add('footer', document.querySelector('footer'));
  return rows.join('\\n');
})()
"""

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: cssWidth, height: 1000))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: cssWidth, height: 1000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let output: String

    init(output: String) {
        self.output = output
        super.init()
        window.colorSpace = .sRGB
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))   // off every screen
        window.orderFrontRegardless()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.capture() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("the page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("the page failed to load: \(error.localizedDescription)")
    }

    @MainActor func capture() async {
        do {
            // The fonts are inside the page, but they still have to be decoded
            // before anything is measured or drawn.
            _ = try await web.callAsyncJavaScript("await document.fonts.ready", contentWorld: .page)
            let height = Int((try await web.evaluateJavaScript("document.documentElement.scrollHeight") as? Double) ?? 0)
            guard height > 0 else { fail("the page has no height") }
            window.setContentSize(NSSize(width: cssWidth, height: height))
            web.frame = NSRect(x: 0, y: 0, width: cssWidth, height: height)
            try await Task.sleep(nanoseconds: 500_000_000)
            print("Where each part sits in \(output), in pixels:")
            print(try await web.evaluateJavaScript(measure) as? String ?? "")
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: cssWidth, height: height)
            config.afterScreenUpdates = true
            let image = try await web.takeSnapshot(configuration: config)
            writePNG(image, to: output, width: cssWidth * scale, height: height * scale)
            print("wrote \(output), \(cssWidth * scale) by \(height * scale) pixels")
            exit(0)
        } catch {
            fail("\(error)")
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--strip" {
    guard args.count > 1 else { fail("--strip needs at least one PNG") }
    for path in args.dropFirst() { strip(path) }
    exit(0)
}
guard args.count == 2 else {
    fail("usage: swift Scripts/snapshot.swift DASHBOARD.html PAGE.png, or --strip FILE.png...")
}
let page = URL(fileURLWithPath: args[0]).standardizedFileURL
guard FileManager.default.fileExists(atPath: page.path) else { fail("there is no page at \(page.path)") }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(output: args[1])
renderer.web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fail("timed out after 60 seconds") }
app.run()
