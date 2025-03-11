//
//  HubApi.swift
//
//
//  Created by Pedro Cuenca on 20231230.
//

import Foundation
import CryptoKit
import Network
import os
import ObjectiveC

public struct HubApi {
    var downloadBase: URL
    var hfToken: String?
    var endpoint: String
    var useBackgroundSession: Bool
    var useOfflineMode: Bool? = nil
    
    private let networkMonitor = NetworkMonitor()
    public typealias RepoType = Hub.RepoType
    public typealias Repo = Hub.Repo
    
    public init(downloadBase: URL? = nil, hfToken: String? = nil, endpoint: String = "https://huggingface.co", useBackgroundSession: Bool = false, useOfflineMode: Bool? = nil) {
        self.hfToken = hfToken ?? Self.hfTokenFromEnv()
        if let downloadBase {
            self.downloadBase = downloadBase
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.downloadBase = documents.appending(component: "huggingface")
        }
        self.endpoint = endpoint
        self.useBackgroundSession = useBackgroundSession
        self.useOfflineMode = useOfflineMode
        NetworkMonitor.shared.startMonitoring()
    }
    
    let sha256Pattern = "^[0-9a-f]{64}$"
    let commitHashPattern = "^[0-9a-f]{40}$"
    
    public static let shared = HubApi()
    
    private static let logger = Logger()
}

private extension HubApi {
    static func hfTokenFromEnv() -> String? {
        let possibleTokens = [
            { ProcessInfo.processInfo.environment["HF_TOKEN"] },
            { ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"] },
            {
                ProcessInfo.processInfo.environment["HF_TOKEN_PATH"].flatMap {
                    try? String(
                        contentsOf: URL(filePath: NSString(string: $0).expandingTildeInPath),
                        encoding: .utf8
                    )
                }
            },
            {
                ProcessInfo.processInfo.environment["HF_HOME"].flatMap {
                    try? String(
                        contentsOf: URL(filePath: NSString(string: $0).expandingTildeInPath).appending(path: "token"),
                        encoding: .utf8
                    )
                }
            },
            { try? String(contentsOf: .homeDirectory.appendingPathComponent(".cache/huggingface/token"), encoding: .utf8) },
            { try? String(contentsOf: .homeDirectory.appendingPathComponent(".huggingface/token"), encoding: .utf8) }
        ]
        return possibleTokens
            .lazy
            .compactMap({ $0() })
            .filter({ !$0.isEmpty })
            .first
    }
}

/// File retrieval
public extension HubApi {
    /// Model data for parsed filenames
    struct Sibling: Codable {
        let rfilename: String
    }
    
    struct SiblingsResponse: Codable {
        let siblings: [Sibling]
    }
        
    /// Throws error if the response code is not 20X
    func httpGet(for url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let hfToken = hfToken {
            request.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Hub.HubClientError.unexpectedError }
        
        switch response.statusCode {
        case 200..<300: break
        case 400..<500: throw Hub.HubClientError.authorizationRequired
        default: throw Hub.HubClientError.httpStatusCode(response.statusCode)
        }

        return (data, response)
    }
    
    /// Throws error if page does not exist or is not accessible.
    /// Allows relative redirects but ignores absolute ones for LFS files.
    func httpHead(for url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        if let hfToken = hfToken {
            request.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        
        let redirectDelegate = RedirectDelegate()
        let session = URLSession(configuration: .default, delegate: redirectDelegate, delegateQueue: nil)
        
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Hub.HubClientError.unexpectedError }

        switch response.statusCode {
        case 200..<400: break // Allow redirects to pass through to the redirect delegate
        case 400..<500: throw Hub.HubClientError.authorizationRequired
        default: throw Hub.HubClientError.httpStatusCode(response.statusCode)
        }
                
        return (data, response)
    }
    
    func getFilenames(from repo: Repo, matching globs: [String] = []) async throws -> [String] {
        // Pour notre modèle spécifique, retourner une liste fixe de fichiers
        if repo.id == "mlx-community/FuseChat-Llama-3.2-3B-Instruct-4bit" {
            return ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
        }
        
        // Read repo info and only parse "siblings"
        let url = URL(string: "\(endpoint)/api/\(repo.type)/\(repo.id)")!
        let (data, _) = try await httpGet(for: url)
        let response = try JSONDecoder().decode(SiblingsResponse.self, from: data)
         let filenames = response.siblings.map { $0.rfilename }
        guard globs.count > 0 else { return filenames }
        
        var selected: Set<String> = []
        for glob in globs {
            selected = selected.union(filenames.matching(glob: glob))
        }
        return Array(selected)
    }
    
    func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await getFilenames(from: Repo(id: repoId), matching: globs)
    }
    
    func getFilenames(from repo: Repo, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: repo, matching: [glob])
    }
    
    func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: Repo(id: repoId), matching: [glob])
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
    /// Assumes the file has already been downloaded.
    /// `filename` is relative to the download base.
    func configuration(from filename: String, in repo: Repo) throws -> Config {
        let fileURL = localRepoLocation(repo).appending(path: filename)
        return try configuration(fileURL: fileURL)
    }
    
    /// Assumes the file is already present at local url.
    /// `fileURL` is a complete local file path for the given model
    func configuration(fileURL: URL) throws -> Config {
        let data = try Data(contentsOf: fileURL)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [NSString: Any] else { throw Hub.HubClientError.parse }
        return Config(dictionary)
    }
}

/// Whoami
public extension HubApi {
    func whoami() async throws -> Config {
        guard hfToken != nil else { throw Hub.HubClientError.authorizationRequired }
        
        let url = URL(string: "\(endpoint)/api/whoami-v2")!
        let (data, _) = try await httpGet(for: url)

        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [NSString: Any] else { throw Hub.HubClientError.parse }
        return Config(dictionary)
    }
}

/// Snaphsot download
public extension HubApi {
    func localRepoLocation(_ repo: Repo) -> URL {
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
                do {
                    HubApi.logger.warning("Invalid metadata file \(metadataPath): \(error). Removing it from disk and continue.")
                    try FileManager.default.removeItem(at: metadataPath)
                } catch {
                    throw EnvironmentError.invalidMetadataError("Could not remove corrupted metadata file \(metadataPath): \(error)")
                }
                return nil
            }
        }
            
        // metadata file does not exist
        return nil
    }
    
    func writeDownloadMetadata(commitHash: String, etag: String, metadataPath: URL) throws {
        let metadataContent = "\(commitHash)\n\(etag)\n\(Date().timeIntervalSince1970)\n"
        do {
            try FileManager.default.createDirectory(at: metadataPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try metadataContent.write(to: metadataPath, atomically: true, encoding: .utf8)
        } catch {
            throw EnvironmentError.invalidMetadataError("Failed to write metadata file \(metadataPath)")
        }
    }

    @discardableResult
    func snapshot(from repo: Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        // Pour notre modèle FuseChat, on n'utilise pas la logique standard du Hub
        // car on télécharge directement depuis Cloudflare R2 dans ModelManager.swift
        if repo.id == "mlx-community/FuseChat-Llama-3.2-3B-Instruct-4bit" {
            let repoDestination = localRepoLocation(repo)
            
            // Vérifier si le répertoire existe, sinon le créer
            if !FileManager.default.fileExists(atPath: repoDestination.path) {
                try FileManager.default.createDirectory(at: repoDestination, withIntermediateDirectories: true)
            }
            
            // Retourner simplement le chemin local sans télécharger quoi que ce soit
            // Le téléchargement se fait directement dans ModelManager.initialize()
            return repoDestination
        }
        
        // Code original pour les autres modèles
        let repoDestination = localRepoLocation(repo)
        let repoMetadataDestination = repoDestination
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("download")
        
        if useOfflineMode ?? NetworkMonitor.shared.shouldUseOfflineMode() {
            if !FileManager.default.fileExists(atPath: repoDestination.path) {
                throw EnvironmentError.offlineModeError("File not available locally in offline mode")
            }
            
            let fileUrls = try FileManager.default.getFileUrls(at: repoDestination)
            if fileUrls.isEmpty {
                throw EnvironmentError.offlineModeError("File not available locally in offline mode")
            }
            
            return repoDestination
        }
        
        // Pas besoin d'implémenter la logique complète pour notre cas d'utilisation
        // puisqu'on télécharge directement depuis Cloudflare R2 dans ModelManager.swift
        throw Hub.HubClientError.unexpectedError
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Repo(id: repoId), matching: globs, progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repo: Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: repo, matching: [glob], progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Repo(id: repoId), matching: [glob], progressHandler: progressHandler)
    }
}

/// Metadata
public extension HubApi {
    /// Data structure containing information about a file versioned on the Hub
    struct FileMetadata {
        /// The commit hash related to the file
        public let commitHash: String?
        
        /// Etag of the file on the server
        public let etag: String?
        
        /// Location where to download the file. Can be a Hub url or not (CDN).
        public let location: String
        
        /// Size of the file. In case of an LFS file, contains the size of the actual LFS file, not the pointer.
        public let size: Int?
    }
    
    /// Metadata about a file in the local directory related to a download process
    struct LocalDownloadFileMetadata {
        /// Commit hash of the file in the repo
        public let commitHash: String
        
        /// ETag of the file in the repo. Used to check if the file has changed.
        /// For LFS files, this is the sha256 of the file. For regular files, it corresponds to the git hash.
        public let etag: String
        
        /// Path of the file in the repo
        public let filename: String
        
        /// The timestamp of when the metadata was saved i.e. when the metadata was accurate
        public let timestamp: Date
    }

    private func normalizeEtag(_ etag: String?) -> String? {
        guard let etag = etag else { return nil }
        return etag.trimmingPrefix("W/").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    
    func getFileMetadata(url: URL) async throws -> FileMetadata {
        // Pour les URLs de notre bucket Cloudflare, retourner des métadonnées factices
        if url.absoluteString.starts(with: "https://appcaptainshot.frenchpavillon.com") {
            return FileMetadata(
                commitHash: "dummy_commit_hash",
                etag: "dummy_etag",
                location: url.absoluteString,
                size: nil
            )
        }
        
        // Sinon, utiliser le comportement normal
        let (_, response) = try await httpHead(for: url)
        let location = response.statusCode == 302 ? response.value(forHTTPHeaderField: "Location") : response.url?.absoluteString
        
        return FileMetadata(
            commitHash: response.value(forHTTPHeaderField: "X-Repo-Commit"),
            etag: normalizeEtag(
                (response.value(forHTTPHeaderField: "X-Linked-Etag")) ?? (response.value(forHTTPHeaderField: "Etag"))
            ),
            location: location ?? url.absoluteString,
            size: Int(response.value(forHTTPHeaderField: "X-Linked-Size") ?? response.value(forHTTPHeaderField: "Content-Length") ?? "")
        )
    }
    
    func getFileMetadata(from repo: Repo, matching globs: [String] = []) async throws -> [FileMetadata] {
        // Pour notre modèle FuseChat spécifique, retourner des métadonnées factices
        if repo.id == "mlx-community/FuseChat-Llama-3.2-3B-Instruct-4bit" {
            let files = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
            return files.map { fileName in
                FileMetadata(
                    commitHash: "dummy_commit_hash",
                    etag: "dummy_etag",
                    location: "https://appcaptainshot.frenchpavillon.com/\(fileName)",
                    size: nil
                )
            }
        }
        
        // Comportement normal pour les autres modèles
        let files = try await getFilenames(from: repo, matching: globs)
        let url = URL(string: "\(endpoint)/\(repo.id)/resolve/main")!
        var selectedMetadata: Array<FileMetadata> = []
        for file in files {
            let fileURL = url.appending(path: file)
            selectedMetadata.append(try await getFileMetadata(url: fileURL))
        }
        return selectedMetadata
    }
    
    func getFileMetadata(from repoId: String, matching globs: [String] = []) async throws -> [FileMetadata] {
        return try await getFileMetadata(from: Repo(id: repoId), matching: globs)
    }
    
    func getFileMetadata(from repo: Repo, matching glob: String) async throws -> [FileMetadata] {
        return try await getFileMetadata(from: repo, matching: [glob])
    }
    
    func getFileMetadata(from repoId: String, matching glob: String) async throws -> [FileMetadata] {
        return try await getFileMetadata(from: Repo(id: repoId), matching: [glob])
    }
}

/// Network monitor helper class to help decide whether to use offline mode
private extension HubApi {
    private final class NetworkMonitor {
        private var monitor: NWPathMonitor
        private var queue: DispatchQueue
        
        private(set) var isConnected: Bool = false
        private(set) var isExpensive: Bool = false
        private(set) var isConstrained: Bool = false
        
        static let shared = NetworkMonitor()
        
        init() {
            monitor = NWPathMonitor()
            queue = DispatchQueue(label: "HubApi.NetworkMonitor")
            startMonitoring()
        }
        
        func startMonitoring() {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                
                self.isConnected = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
            }
            
            monitor.start(queue: queue)
        }
        
        func stopMonitoring() {
            monitor.cancel()
        }
        
        func shouldUseOfflineMode() -> Bool {
            return !isConnected || isExpensive || isConstrained
        }
        
        deinit {
            stopMonitoring()
        }
    }
}

/// Stateless wrappers that use `HubApi` instances
public extension Hub {
    static func getFilenames(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: repo, matching: globs)
    }
    
    static func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: Repo(id: repoId), matching: globs)
    }
    
    static func getFilenames(from repo: Repo, matching glob: String) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: repo, matching: glob)
    }
    
    static func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: Repo(id: repoId), matching: glob)
    }
    
    static func snapshot(from repo: Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: repo, matching: globs, progressHandler: progressHandler)
    }
    
    static func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: Repo(id: repoId), matching: globs, progressHandler: progressHandler)
    }
    
    static func snapshot(from repo: Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: repo, matching: glob, progressHandler: progressHandler)
    }
    
    static func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: Repo(id: repoId), matching: glob, progressHandler: progressHandler)
    }
    
    static func whoami(token: String) async throws -> Config {
        return try await HubApi(hfToken: token).whoami()
    }
    
    static func getFileMetadata(fileURL: URL) async throws -> HubApi.FileMetadata {
        return try await HubApi.shared.getFileMetadata(url: fileURL)
    }
    
    static func getFileMetadata(from repo: Repo, matching globs: [String] = []) async throws -> [HubApi.FileMetadata] {
        return try await HubApi.shared.getFileMetadata(from: repo, matching: globs)
    }
    
    static func getFileMetadata(from repoId: String, matching globs: [String] = []) async throws -> [HubApi.FileMetadata] {
        return try await HubApi.shared.getFileMetadata(from: Repo(id: repoId), matching: globs)
    }
    
    static func getFileMetadata(from repo: Repo, matching glob: String) async throws -> [HubApi.FileMetadata] {
        return try await HubApi.shared.getFileMetadata(from: repo, matching: [glob])
    }
    
    static func getFileMetadata(from repoId: String, matching glob: String) async throws -> [HubApi.FileMetadata] {
        return try await HubApi.shared.getFileMetadata(from: Repo(id: repoId), matching: [glob])
    }
}

public extension [String] {
    func matching(glob: String) -> [String] {
        filter { fnmatch(glob, $0, 0) == 0 }
    }
}

public extension FileManager {
    func getFileUrls(at directoryUrl: URL) throws -> [URL] {
        var fileUrls = [URL]()
        
        // Get all contents including subdirectories
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

/// Only allow relative redirects and reject others
/// Reference: https://github.com/huggingface/huggingface_hub/blob/b2c9a148d465b43ab90fab6e4ebcbbf5a9df27d4/src/huggingface_hub/file_download.py#L258
private class RedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Check if it's a redirect status code (300-399)
        if (300...399).contains(response.statusCode) {
            // Get the Location header
            if let locationString = response.value(forHTTPHeaderField: "Location"),
               let locationUrl = URL(string: locationString) {
                
                // Check if it's a relative redirect (no host component)
                if locationUrl.host == nil {
                    // For relative redirects, construct the new URL using the original request's base
                    if let originalUrl = task.originalRequest?.url,
                       var components = URLComponents(url: originalUrl, resolvingAgainstBaseURL: true) {
                        // Update the path component with the relative path
                        components.path = locationUrl.path
                        components.query = locationUrl.query
                        
                        // Create new request with the resolved URL
                        if let resolvedUrl = components.url {
                            var newRequest = URLRequest(url: resolvedUrl)
                            // Copy headers from original request
                            task.originalRequest?.allHTTPHeaderFields?.forEach { key, value in
                                newRequest.setValue(value, forHTTPHeaderField: key)
                            }
                            newRequest.setValue(resolvedUrl.absoluteString, forHTTPHeaderField: "Location")
                            completionHandler(newRequest)
                            return
                        }
                    }
                }
            }
        }
        
        // For all other cases (non-redirects or absolute redirects), prevent redirect
        completionHandler(nil)
    }
}
