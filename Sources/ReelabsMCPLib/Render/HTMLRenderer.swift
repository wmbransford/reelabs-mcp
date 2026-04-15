import Foundation
import WebKit
import AppKit

package enum HTMLRenderError: LocalizedError {
    case timeout
    case navigationFailed(String)
    case pngConversionFailed

    package var errorDescription: String? {
        switch self {
        case .timeout:
            return "HTML rendering timed out"
        case .navigationFailed(let message):
            return "Navigation failed: \(message)"
        case .pngConversionFailed:
            return "Failed to convert snapshot to PNG"
        }
    }
}

@MainActor
package enum HTMLRenderer {

    package static func render(
        html: String, width: Int, height: Int,
        outputURL: URL, timeout: TimeInterval = 10
    ) async throws -> Int64 {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Frame in points = CSS viewport in px. HTML designed for 1920x1080
        // gets a 1920x1080 CSS viewport regardless of display scale.
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = NavigationDelegate(continuation: continuation)
            webView.navigationDelegate = delegate
            // Prevent premature dealloc of the delegate
            objc_setAssociatedObject(webView, "navDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            webView.loadHTMLString(html, baseURL: nil)

            // Timeout watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak delegate] in
                delegate?.timeoutIfNeeded()
            }
        }

        // Brief delay for CSS paint completion
        try await Task.sleep(nanoseconds: 100_000_000)

        // snapshotWidth is in points; at 2x scale, width/scale points = width pixels
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.snapshotWidth = NSNumber(value: Double(width) / Double(scale))

        let image = try await webView.takeSnapshot(configuration: snapshotConfig)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw HTMLRenderError.pngConversionFailed
        }

        try pngData.write(to: outputURL)
        return Int64(pngData.count)
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: HTMLRenderError.navigationFailed(error.localizedDescription))
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: HTMLRenderError.navigationFailed(error.localizedDescription))
        continuation = nil
    }

    func timeoutIfNeeded() {
        continuation?.resume(throwing: HTMLRenderError.timeout)
        continuation = nil
    }
}
