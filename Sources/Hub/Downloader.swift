import Foundation
import Combine

class Downloader: NSObject {
    private(set) var destination: URL
    private let chunkSize = 10 * 1024 * 1024  // 10MB
    
    enum DownloadState {
        case notStarted
        case downloading(Double)
        case completed(URL)
        case failed(Error)
    }

    enum DownloadError: Error {
        case invalidDownloadLocation
        case unexpectedError
    }

    private(set) lazy var downloadState: CurrentValueSubject<DownloadState, Never> = CurrentValueSubject(.notStarted)
    private var stateSubscriber: Cancellable?
    private var urlSession: URLSession?

    init(
        from url: URL,
        to destination: URL,
        inBackground: Bool = false,
        timeout: TimeInterval = 10
    ) {
        self.destination = destination
        super.init()
        
        let sessionIdentifier = "swift-transformers.hub.downloader"
        var config = URLSessionConfiguration.default
        
        if inBackground {
            config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
        }

        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        downloadState.value = .downloading(0)
        
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        
        Task {
            do {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                let tempFile = try FileHandle(forWritingTo: tempURL)
                
                defer { tempFile.closeFile() }
                
                let (asyncBytes, response) = try await urlSession!.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw DownloadError.unexpectedError
                }
                
                var downloadedSize = 0
                var buffer = Data(capacity: chunkSize)
                
                for try await byte in asyncBytes {
                    buffer.append(byte)
                    if buffer.count == chunkSize {
                        try tempFile.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                        downloadedSize += chunkSize
                        let progress = Double(downloadedSize) / Double(response.expectedContentLength)
                        downloadState.value = .downloading(progress)
                    }
                }
                
                if !buffer.isEmpty {
                    try tempFile.write(contentsOf: buffer)
                    downloadedSize += buffer.count
                }
                
                tempFile.closeFile()
                try FileManager.default.moveDownloadedFile(from: tempURL, to: self.destination)
                downloadState.value = .completed(self.destination)
                
            } catch {
                downloadState.value = .failed(error)
            }
        }
    }

    @discardableResult
    func waitUntilDone() async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let semaphore = DispatchSemaphore(value: 0)
            
            stateSubscriber = downloadState.sink { state in
                switch state {
                case .completed(let url):
                    continuation.resume(returning: url)
                    semaphore.signal()
                case .failed(let error):
                    continuation.resume(throwing: error)
                    semaphore.signal()
                default:
                    break
                }
            }
            
            Task {
                try await Task.sleep(nanoseconds: 100_000_000)
                semaphore.wait()
            }
        }
    }

    func cancel() {
        urlSession?.invalidateAndCancel()
    }
}

extension Downloader: URLSessionDownloadDelegate {
    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        downloadState.value = .downloading(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveDownloadedFile(from: location, to: self.destination)
            downloadState.value = .completed(destination)
        } catch {
            downloadState.value = .failed(error)
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            downloadState.value = .failed(error)
        }
    }
}

extension FileManager {
    func moveDownloadedFile(from srcURL: URL, to dstURL: URL) throws {
        if fileExists(atPath: dstURL.path) {
            try removeItem(at: dstURL)
        }
        try moveItem(at: srcURL, to: dstURL)
    }
}

