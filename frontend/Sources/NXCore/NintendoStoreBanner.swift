import Foundation

/// Resolves official 16:9 key art directly from Nintendo's regional store pages (`ec.nintendo.com/apps/<TID>/US|HK`).
/// Works for Switch 2 (`0400...`) titles and regional Switch 1 releases absent from `api.nlib.cc` or `blawar/titledb`.
package enum NintendoStoreBanner {
    package static let regions = ["US", "HK"]
    package static let requestTimeout: TimeInterval = 8
    package static let maxHTMLBytes = 8 * 1024 * 1024
    package static let maxImageBytes = 16 * 1024 * 1024
    package static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    package struct HTTPResponse: Sendable {
        package var statusCode: Int
        package var finalURL: URL
        package var data: Data

        package init(statusCode: Int, finalURL: URL, data: Data) {
            self.statusCode = statusCode
            self.finalURL = finalURL
            self.data = data
        }
    }

    package enum FetchOutcome: Equatable, Sendable {
        case image(Data, sourceURL: URL)
        case notFound
        case transientError
    }

    package typealias AsyncTransport = @Sendable (URLRequest, Int) async throws -> HTTPResponse
    package typealias SyncTransport = @Sendable (URLRequest, Int) throws -> HTTPResponse

    private enum TransportError: Error {
        case responseTooLarge
        case disallowedRedirect
        case missingHTTPResponse
        case timedOut
    }

    package static func storePageURL(for titleID: String, region: String) -> URL? {
        let id = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let reg = region.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard KnownGameBanners.isValidTitleID(id), !reg.isEmpty else { return nil }
        return URL(string: "https://ec.nintendo.com/apps/\(id)/\(reg)")
    }

    /// Extracts an official banner image URL from a Nintendo US/HK store HTML page.
    package static func extractBannerURL(from html: String) -> URL? {
        if let url = extractFromNextData(html) { return url }
        if let url = extractFromAssetsRegex(html) { return url }
        if let url = extractFromOpenGraph(html) { return url }
        return nil
    }

    private static func extractFromNextData(_ html: String) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script\b[^>]*\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>([\s\S]*?)</script>"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let nsHTML = html as NSString
        let range = NSRange(location: 0, length: nsHTML.length)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        let jsonText = nsHTML.substring(with: match.range(at: 1))
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let linkedData = pageProps["linkedData"] else { return nil }

        let objects: [[String: Any]]
        if let dict = linkedData as? [String: Any] {
            objects = [dict]
        } else if let array = linkedData as? [Any] {
            objects = array.compactMap { $0 as? [String: Any] }
        } else {
            return nil
        }

        for obj in objects {
            if let raw = obj["image"] as? String, let url = validatedAssetsURL(raw) {
                return url
            }
            if let list = obj["image"] as? [String] {
                for raw in list {
                    if let url = validatedAssetsURL(raw) { return url }
                }
            }
        }
        return nil
    }

    private static func extractFromAssetsRegex(_ html: String) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: #""image"\s*:\s*"(https://assets\.nintendo\.com/image/upload/[^"]*/store/software/switch2?/[0-9]+/[^"]+)""#,
            options: []
        ) else { return nil }
        let nsHTML = html as NSString
        let range = NSRange(location: 0, length: nsHTML.length)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        let raw = nsHTML.substring(with: match.range(at: 1))
        return validatedAssetsURL(raw)
    }

    private static func extractFromOpenGraph(_ html: String) -> URL? {
        guard let metaRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]+>"#, options: [.caseInsensitive]),
              let propRegex = try? NSRegularExpression(
                  pattern: #"\bproperty\s*=\s*["']og:image["']"#,
                  options: [.caseInsensitive]
              ),
              let contentRegex = try? NSRegularExpression(
                  pattern: #"\bcontent\s*=\s*["'](https://img-eshop\.cdn\.nintendo\.net/i/[0-9a-fA-F]+\.(?:jpg|png|webp))["']"#,
                  options: [.caseInsensitive]
              ) else { return nil }

        let nsHTML = html as NSString
        let matches = metaRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
        for m in matches {
            let tag = nsHTML.substring(with: m.range)
            let nsTag = tag as NSString
            let tagRange = NSRange(location: 0, length: nsTag.length)
            guard propRegex.firstMatch(in: tag, options: [], range: tagRange) != nil,
                  let contentMatch = contentRegex.firstMatch(in: tag, options: [], range: tagRange),
                  contentMatch.numberOfRanges > 1,
                  contentMatch.range(at: 1).location != NSNotFound else { continue }
            let raw = nsTag.substring(with: contentMatch.range(at: 1))
            if let url = URL(string: raw), KnownGameBanners.isAllowedURL(url) {
                return url
            }
        }
        return nil
    }

    private static func validatedAssetsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "assets.nintendo.com" else { return nil }
        return url
    }

    private static func makePageRequest(url: URL, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(2, timeout))
        req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return req
    }

    private static func makeImageRequest(url: URL, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(2, timeout))
        req.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("image/jpeg,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
        return req
    }

    private static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Asynchronously probes Nintendo US -> HK official store pages for `titleID`, validates redirect hosts and
    /// landscape dimensions, and returns JPEG-normalized banner bytes.
    package static func fetchBanner(
        titleID: String,
        timeout: TimeInterval = requestTimeout,
        transport: AsyncTransport? = nil
    ) async -> FetchOutcome {
        let id = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard KnownGameBanners.isValidTitleID(id) else { return .notFound }
        if transport == nil && isRunningUnderTests {
            return .notFound
        }
        let run = transport ?? defaultAsyncTransport
        let effectiveTimeout = max(2, min(timeout, requestTimeout))
        var hadTransientError = false

        for region in regions {
            if Task.isCancelled { return .transientError }
            guard let pageURL = storePageURL(for: id, region: region) else { continue }
            let pageReq = makePageRequest(url: pageURL, timeout: effectiveTimeout)
            let pageResp: HTTPResponse
            do {
                pageResp = try await run(pageReq, maxHTMLBytes)
            } catch {
                if !isPolicyRejection(error) { hadTransientError = true }
                continue
            }

            if pageResp.statusCode == 404 || pageResp.statusCode == 410 {
                continue
            }
            if pageResp.statusCode >= 500 {
                hadTransientError = true
                continue
            }
            guard (200...299).contains(pageResp.statusCode),
                  KnownGameBanners.isAllowedStoreURL(pageResp.finalURL),
                  pageResp.data.count <= maxHTMLBytes else { continue }

            let html = String(decoding: pageResp.data, as: UTF8.self)
            guard let imageURL = extractBannerURL(from: html),
                  KnownGameBanners.isAllowedURL(imageURL) else { continue }

            let imgReq = makeImageRequest(url: imageURL, timeout: effectiveTimeout)
            let imgResp: HTTPResponse
            do {
                imgResp = try await run(imgReq, maxImageBytes)
            } catch {
                if !isPolicyRejection(error) { hadTransientError = true }
                continue
            }
            if imgResp.statusCode >= 500 {
                hadTransientError = true
                continue
            }
            guard (200...299).contains(imgResp.statusCode),
                  KnownGameBanners.isAllowedURL(imgResp.finalURL),
                  imgResp.data.count <= maxImageBytes,
                  KnownGameBanners.isValidLandscapeImageData(imgResp.data, maxBytes: maxImageBytes),
                  let jpeg = KnownGameBanners.normalizedJPEGData(imgResp.data, maxBytes: maxImageBytes) else {
                continue
            }
            return .image(jpeg, sourceURL: imgResp.finalURL)
        }
        return hadTransientError ? .transientError : .notFound
    }

    /// Synchronous counterpart for packaging backfills (`BannerCache.ensureCachedBanner`).
    package static func fetchBannerSync(
        titleID: String,
        timeout: TimeInterval = requestTimeout,
        transport: SyncTransport? = nil
    ) -> FetchOutcome {
        let id = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard KnownGameBanners.isValidTitleID(id) else { return .notFound }
        if transport == nil && isRunningUnderTests {
            return .notFound
        }
        let run = transport ?? defaultSyncTransport
        let effectiveTimeout = max(2, min(timeout, requestTimeout))
        var hadTransientError = false

        for region in regions {
            guard let pageURL = storePageURL(for: id, region: region) else { continue }
            let pageReq = makePageRequest(url: pageURL, timeout: effectiveTimeout)
            let pageResp: HTTPResponse
            do {
                pageResp = try run(pageReq, maxHTMLBytes)
            } catch {
                if !isPolicyRejection(error) { hadTransientError = true }
                continue
            }

            if pageResp.statusCode == 404 || pageResp.statusCode == 410 {
                continue
            }
            if pageResp.statusCode >= 500 {
                hadTransientError = true
                continue
            }
            guard (200...299).contains(pageResp.statusCode),
                  KnownGameBanners.isAllowedStoreURL(pageResp.finalURL),
                  pageResp.data.count <= maxHTMLBytes else { continue }

            let html = String(decoding: pageResp.data, as: UTF8.self)
            guard let imageURL = extractBannerURL(from: html),
                  KnownGameBanners.isAllowedURL(imageURL) else { continue }

            let imgReq = makeImageRequest(url: imageURL, timeout: effectiveTimeout)
            let imgResp: HTTPResponse
            do {
                imgResp = try run(imgReq, maxImageBytes)
            } catch {
                if !isPolicyRejection(error) { hadTransientError = true }
                continue
            }
            if imgResp.statusCode >= 500 {
                hadTransientError = true
                continue
            }
            guard (200...299).contains(imgResp.statusCode),
                  KnownGameBanners.isAllowedURL(imgResp.finalURL),
                  imgResp.data.count <= maxImageBytes,
                  KnownGameBanners.isValidLandscapeImageData(imgResp.data, maxBytes: maxImageBytes),
                  let jpeg = KnownGameBanners.normalizedJPEGData(imgResp.data, maxBytes: maxImageBytes) else {
                continue
            }
            return .image(jpeg, sourceURL: imgResp.finalURL)
        }
        return hadTransientError ? .transientError : .notFound
    }

    private static func isPolicyRejection(_ error: Error) -> Bool {
        if let err = error as? TransportError {
            return err == .disallowedRedirect || err == .responseTooLarge
        }
        return false
    }

    private static func isAllowedDestination(_ url: URL, forOriginal original: URL?) -> Bool {
        if let original, KnownGameBanners.isAllowedStoreURL(original) && original.host?.lowercased() == "ec.nintendo.com" {
            return KnownGameBanners.isAllowedStoreURL(url)
        }
        return KnownGameBanners.isAllowedURL(url)
    }

    private final class BoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let originalURL: URL?
        let maxBytes: Int
        private let onComplete: @Sendable (Result<HTTPResponse, Error>) -> Void
        private let lock = NSLock()
        private var buffer = Data()
        private var httpResponse: HTTPURLResponse?
        private var capturedError: Error?
        private var finished = false

        init(originalURL: URL?, maxBytes: Int, onComplete: @escaping @Sendable (Result<HTTPResponse, Error>) -> Void) {
            self.originalURL = originalURL
            self.maxBytes = maxBytes
            self.onComplete = onComplete
        }

        private func emitOnce(_ result: Result<HTTPResponse, Error>) {
            let shouldEmit = lock.withLock { () -> Bool in
                guard !finished else { return false }
                finished = true
                return true
            }
            if shouldEmit {
                onComplete(result)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let target = request.url, isAllowedDestination(target, forOriginal: originalURL) else {
                lock.withLock { capturedError = TransportError.disallowedRedirect }
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
                lock.withLock { capturedError = TransportError.missingHTTPResponse }
                completionHandler(.cancel)
                return
            }
            guard isAllowedDestination(finalURL, forOriginal: originalURL) else {
                lock.withLock { capturedError = TransportError.disallowedRedirect }
                completionHandler(.cancel)
                return
            }
            if http.expectedContentLength > Int64(maxBytes) {
                lock.withLock { capturedError = TransportError.responseTooLarge }
                completionHandler(.cancel)
                return
            }
            lock.withLock { httpResponse = http }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let overflow = lock.withLock { () -> Bool in
                if buffer.count + data.count > maxBytes {
                    capturedError = TransportError.responseTooLarge
                    return true
                }
                buffer.append(data)
                return false
            }
            if overflow {
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let result: Result<HTTPResponse, Error> = lock.withLock {
                if let capturedError { return .failure(capturedError) }
                if let error { return .failure(error) }
                guard let http = httpResponse, let finalURL = http.url else {
                    return .failure(TransportError.missingHTTPResponse)
                }
                return .success(HTTPResponse(statusCode: http.statusCode, finalURL: finalURL, data: buffer))
            }
            emitOnce(result)
        }
    }

    private static let defaultAsyncTransport: AsyncTransport = { request, maxBytes in
        let config = URLSessionConfiguration.ephemeral
        let timeout = max(2, request.timeoutInterval)
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(4, timeout * 1.5)
        final class TaskBox: @unchecked Sendable {
            private let lock = NSLock()
            private var task: URLSessionDataTask?
            private var cancelled = false
            func set(_ t: URLSessionDataTask) {
                let shouldCancel = lock.withLock { () -> Bool in
                    task = t
                    return cancelled
                }
                if shouldCancel { t.cancel() }
            }
            func cancel() {
                let current = lock.withLock { () -> URLSessionDataTask? in
                    cancelled = true
                    return task
                }
                current?.cancel()
            }
        }
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let delegate = BoundedDataDelegate(originalURL: request.url, maxBytes: maxBytes) { result in
                    cont.resume(with: result)
                }
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)
                box.set(task)
                task.resume()
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static let defaultSyncTransport: SyncTransport = { request, maxBytes in
        let config = URLSessionConfiguration.ephemeral
        let timeout = max(2, request.timeoutInterval)
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(4, timeout * 1.5)
        final class Box: @unchecked Sendable {
            var result: Result<HTTPResponse, Error> = .failure(TransportError.timedOut)
        }
        let box = Box()
        let sema = DispatchSemaphore(value: 0)
        let delegate = BoundedDataDelegate(originalURL: request.url, maxBytes: maxBytes) { result in
            box.result = result
            sema.signal()
        }
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
        session.finishTasksAndInvalidate()
        let waited = sema.wait(timeout: .now() + max(2, timeout * 1.5))
        if waited == .timedOut {
            task.cancel()
            throw TransportError.timedOut
        }
        return try box.result.get()
    }
}
