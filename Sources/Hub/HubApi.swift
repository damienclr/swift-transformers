import Foundation
import Network
import os

public struct HubApi {
    var downloadBase: URL
    var hfToken: String?
    var endpoint: String
    
    public static var cloudflareR2URL: String = ""
    public static var modelId: String = ""

    public typealias Repo = Hub.Repo
    
    public init(downloadBase: URL? = nil, hfToken: String? = nil, endpoint: String = "https://huggingface.co") {
        self.hfToken = hfToken
        if let downloadBase {
            self.downloadBase = downloadBase
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.downloadBase = documents.appending(component: "huggingface")
        }
        self.endpoint = endpoint
    }
    
    public static let shared = HubApi()
    
    private static let logger = Logger()
}

/// File retrieval
public extension HubApi {
    func getFilenames(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [String] {
        if repo.id == HubApi.modelId {
            return ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
        }
        throw Hub.HubClientError.unexpectedError
    }
    
    func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await getFilenames(from: Hub.Repo(id: repoId), matching: globs)
    }
    
    func getFilenames(from repo: Hub.Repo, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: repo, matching: [glob])
    }
    
    func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: Hub.Repo(id: repoId), matching: glob)
    }
}

/// Additional Errors
public extension HubApi {
    enum EnvironmentError: LocalizedError {
        case invalidMetadataError(String)
        case offlineModeError(String)
                    
        public var errorDescription: String? {
            switch self {
            case .invalidMetadataError(let message),
                 .offlineModeError(let message):
                return message
            }
        }
    }
}

/// Configuration loading helpers
public extension HubApi {
    func configuration(from filename: String, in repo: Hub.Repo) throws -> Config {
        let fileURL = localRepoLocation(repo).appending(path: filename)
        return try configuration(fileURL: fileURL)
    }
    
    func configuration(fileURL: URL) throws -> Config {
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [NSString: Any] else { throw Hub.HubClientError.parse }
        return Config(dictionary)
    }
}

/// Repository location
public extension HubApi {
    func localRepoLocation(_ repo: Hub.Repo) -> URL {
        downloadBase.appending(component: repo.type.rawValue).appending(component: repo.id)
    }
    
    func readDownloadMetadata(metadataPath: URL) throws -> LocalDownloadFileMetadata? {
        if FileManager.default.fileExists(atPath: metadataPath.path) {
            do {
                let contents = try String(contentsOf: metadataPath, encoding: .utf8)
                let lines = contents.components(separatedBy: .newlines)
                
                guard lines.count >= 3 else {
                    throw EnvironmentError.invalidMetadataError("Metadata file is missing required fields.")
                }
                
                let commitHash = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let etag = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timestamp = Double(lines[2].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw EnvironmentError.invalidMetadataError("Missing or invalid timestamp.")
                }
                let timestampDate = Date(timeIntervalSince1970: timestamp)
                        
                let filename = metadataPath.lastPathComponent.replacingOccurrences(of: ".metadata", with: "")
                
                return LocalDownloadFileMetadata(commitHash: commitHash, etag: etag, filename: filename, timestamp: timestampDate)
            } catch {
                return nil
            }
        }
        return nil
    }

    @discardableResult
    func snapshot(from repo: Hub.Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        if repo.id == HubApi.modelId {
            let repoDestination = localRepoLocation(repo)
            
            if !FileManager.default.fileExists(atPath: repoDestination.path) {
                try FileManager.default.createDirectory(at: repoDestination, withIntermediateDirectories: true)
            }
            
            let requiredFiles = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
            let filesExist = requiredFiles.allSatisfy { fileName in
                FileManager.default.fileExists(atPath: repoDestination.appendingPathComponent(fileName).path)
            }
            
            if filesExist {
                print("✅ All model files already exist locally")
            } else {
                print("⚠️ Some model files are missing, will need download")
            }
            
            return repoDestination
        }
        
        throw Hub.HubClientError.unexpectedError
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Hub.Repo(id: repoId), matching: globs, progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repo: Hub.Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: repo, matching: [glob], progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Hub.Repo(id: repoId), matching: [glob], progressHandler: progressHandler)
    }
}

/// Metadata
public extension HubApi {
    struct FileMetadata {
        public let commitHash: String?
        public let etag: String?
        public let location: String
        public let size: Int?
    }
    
    struct LocalDownloadFileMetadata {
        public let commitHash: String
        public let etag: String
        public let filename: String
        public let timestamp: Date
    }

    func getFileMetadata(url: URL) async throws -> FileMetadata {
        if url.absoluteString.starts(with: HubApi.cloudflareR2URL) {
            return FileMetadata(
                commitHash: "dummy_commit_hash",
                etag: "dummy_etag",
                location: url.absoluteString,
                size: nil
            )
        }
        throw Hub.HubClientError.unexpectedError
    }
    
    func getFileMetadata(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [FileMetadata] {
        if repo.id == HubApi.modelId {
            let files = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
            return files.map { fileName in
                FileMetadata(
                    commitHash: "dummy_commit_hash",
                    etag: "dummy_etag",
                    location: "\(HubApi.cloudflareR2URL)/\(fileName)",
                    size: nil
                )
            }
        }
        throw Hub.HubClientError.unexpectedError
    }
    
    func getFileMetadata(from repoId: String, matching globs: [String] = []) async throws -> [FileMetadata] {
            return try await getFileMetadata(from: Hub.Repo(id: repoId), matching: globs)
        }
        
        func getFileMetadata(from repo: Hub.Repo, matching glob: String) async throws -> [FileMetadata] {
            return try await getFileMetadata(from: repo, matching: [glob])
        }
        
        func getFileMetadata(from repoId: String, matching glob: String) async throws -> [FileMetadata] {
            return try await getFileMetadata(from: Hub.Repo(id: repoId), matching: [glob])
        }
    }

    /// Stateless wrappers that use `HubApi` instances
    public extension Hub {
        static func getFilenames(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [String] {
            return try await HubApi.shared.getFilenames(from: repo, matching: globs)
        }
        
        static func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
            return try await HubApi.shared.getFilenames(from: Hub.Repo(id: repoId), matching: globs)
        }
        
        static func getFilenames(from repo: Hub.Repo, matching glob: String) async throws -> [String] {
            return try await HubApi.shared.getFilenames(from: repo, matching: glob)
        }
        
        static func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
            return try await HubApi.shared.getFilenames(from: Hub.Repo(id: repoId), matching: glob)
        }
        
        static func snapshot(from repo: Hub.Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
            return try await HubApi.shared.snapshot(from: repo, matching: globs, progressHandler: progressHandler)
        }
        
        static func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
            return try await HubApi.shared.snapshot(from: Hub.Repo(id: repoId), matching: globs, progressHandler: progressHandler)
        }
        
        static func snapshot(from repo: Hub.Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
            return try await HubApi.shared.snapshot(from: repo, matching: glob, progressHandler: progressHandler)
        }
        
        static func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
            return try await HubApi.shared.snapshot(from: Hub.Repo(id: repoId), matching: glob, progressHandler: progressHandler)
        }
        
        static func getFileMetadata(fileURL: URL) async throws -> HubApi.FileMetadata {
            return try await HubApi.shared.getFileMetadata(url: fileURL)
        }
        
        static func getFileMetadata(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [HubApi.FileMetadata] {
            return try await HubApi.shared.getFileMetadata(from: repo, matching: globs)
        }
        
        static func getFileMetadata(from repoId: String, matching globs: [String] = []) async throws -> [HubApi.FileMetadata] {
            return try await HubApi.shared.getFileMetadata(from: Hub.Repo(id: repoId), matching: globs)
        }
        
        static func getFileMetadata(from repo: Hub.Repo, matching glob: String) async throws -> [HubApi.FileMetadata] {
            return try await HubApi.shared.getFileMetadata(from: repo, matching: [glob])
        }
        
        static func getFileMetadata(from repoId: String, matching glob: String) async throws -> [HubApi.FileMetadata] {
            return try await HubApi.shared.getFileMetadata(from: Hub.Repo(id: repoId), matching: [glob])
        }
    }

    public extension FileManager {
        func getFileUrls(at directoryUrl: URL) throws -> [URL] {
            var fileUrls = [URL]()
            
            guard let enumerator = FileManager.default.enumerator(
                at: directoryUrl,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            ) else {
                return fileUrls
            }
            
            for case let fileURL as URL in enumerator {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                    if resourceValues.isRegularFile == true && resourceValues.isHidden != true {
                        fileUrls.append(fileURL)
                    }
                } catch {
                    throw error
                }
            }
            
            return fileUrls
        }
    }

