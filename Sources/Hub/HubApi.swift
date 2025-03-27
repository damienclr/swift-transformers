import Foundation

struct HubApi {
    var downloadBase: URL = URL(string: "https://appcaptainshot.frenchpavillon.com/")!
    var endpoint: String = "https://appcaptainshot.frenchpavillon.com/"
    var useBackgroundSession: Bool = false
    
    static let shared = HubApi()
    
    func snapshot(from: String, matching: [String]) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        for filename in matching {
            let sourceURL = downloadBase.appendingPathComponent(filename)
            let destination = tempDir.appendingPathComponent(filename)
            
            let downloader = Downloader(
                from: sourceURL,
                to: destination,
                inBackground: useBackgroundSession
            )
            
            _ = try await downloader.waitUntilDone()
        }
        
        return tempDir
    }
    
    func configuration(fileURL: URL) throws -> Config {
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = parsed as? [NSString: Any] else {
            throw DownloadError.invalidDownloadLocation
        }
        return Config(dictionary)
    }
    
    enum DownloadError: Error {
        case invalidDownloadLocation
        case unexpectedError
    }
}

