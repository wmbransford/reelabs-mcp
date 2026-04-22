import Foundation

/// Fire-and-forget POST of render telemetry to the Supabase warehouse.
/// Failure never blocks the render response; errors are logged via captionLog
/// (see CaptionLayer.swift) and swallowed.
///
/// Disabled unless both `REELABS_WAREHOUSE_URL` and `REELABS_WAREHOUSE_SECRET`
/// are set in the process environment. Analytics agent owns this contract:
///   URL:    https://wwqzjgtaystvvxrzzbcw.supabase.co/functions/v1/ingest-video-render
///   Header: x-ingest-secret: <shared secret>
enum WarehouseTelemetry {
    static func postRender(_ payload: [String: Any]) {
        let env = ProcessInfo.processInfo.environment
        guard
            let urlString = env["REELABS_WAREHOUSE_URL"],
            let secret = env["REELABS_WAREHOUSE_SECRET"],
            let url = URL(string: urlString)
        else { return }

        // Serialize the payload on the current thread so the detached Task only
        // captures Sendable types (Data + String + URL). Avoids Swift 6 strict-
        // concurrency errors about [String: Any] crossing an isolation boundary.
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            FileHandle.standardError.write(Data("[warehouse] serialize failed: \(error)\n".utf8))
            return
        }

        // Detach so it never blocks the render response.
        Task.detached(priority: .background) {
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(secret, forHTTPHeaderField: "x-ingest-secret")
                req.httpBody = body
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    FileHandle.standardError.write(Data("[warehouse] ingest returned \(http.statusCode)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("[warehouse] post failed: \(error)\n".utf8))
            }
        }
    }
}
