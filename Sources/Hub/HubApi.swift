//
//  HubApi.swift
//
//
//  Created by Pedro Cuenca on 20231230.
//

import Foundation
import Network
import os

public struct HubApi {
    var downloadBase: URL
    var hfToken: String?
    var endpoint: String
    
    // Nom du modèle à gérer spécialement pour Cloudflare
    private static let cloudflareModelId = "mlx-community/FuseChat-Llama-3.2-3B-Instruct-4bit"
    
    public typealias Repo = Hub.Repo  // Ajout de la référence au type Repo
    
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
    func getFilenames(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [String] {  // Utilisation de Hub.Repo au lieu de Repo
        // Pour notre modèle spécifique, retourner une liste fixe de fichiers
        if repo.id == HubApi.cloudflareModelId {
            return ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
        }
        
        throw Hub.HubClientError.unexpectedError
    }
    
    func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await getFilenames(from: Hub.Repo(id: repoId), matching: globs)  // Utilisation de Hub.Repo
    }
    
    func getFilenames(from repo: Hub.Repo, matching glob: String) async throws -> [String] {  // Utilisation de Hub.Repo
        return try await getFilenames(from: repo, matching: [glob])
    }
    
    func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: Hub.Repo(id: repoId), matching: glob)  // Utilisation de Hub.Repo
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
    func configuration(from filename: String, in repo: Hub.Repo) throws -> Config {  // Utilisation de Hub.Repo
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

/// Repository location
public extension HubApi {
    func localRepoLocation(_ repo: Hub.Repo) -> URL {  // Utilisation de Hub.Repo
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
            
        // metadata file does not exist
        return nil
    }

    @discardableResult
    func snapshot(from repo: Hub.Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {  // Utilisation de Hub.Repo
        // Pour FuseChat, on retourne simplement l'emplacement sans télécharger
        // Le téléchargement se fait dans LLMManager.initialize()
        if repo.id == HubApi.cloudflareModelId {
            let repoDestination = localRepoLocation(repo)
            
            // Vérifier si le répertoire existe, sinon le créer
            if !FileManager.default.fileExists(atPath: repoDestination.path) {
                try FileManager.default.createDirectory(at: repoDestination, withIntermediateDirectories: true)
            }
            
            // Si les fichiers sont déjà présents, pas besoin de connexion internet
            let requiredFiles = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
            let filesExist = requiredFiles.allSatisfy { fileName in
                FileManager.default.fileExists(atPath: repoDestination.appendingPathComponent(fileName).path)
            }
            
            if filesExist {
                print("✅ All model files already exist locally, no internet connection needed")
            } else {
                print("⚠️ Some model files are missing, internet connection will be needed for download")
            }
            
            return repoDestination
        }
        
        throw Hub.HubClientError.unexpectedError
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Hub.Repo(id: repoId), matching: globs, progressHandler: progressHandler)  // Utilisation de Hub.Repo
    }
    
    @discardableResult
    func snapshot(from repo: Hub.Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {  // Utilisation de Hub.Repo
        return try await snapshot(from: repo, matching: [glob], progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Hub.Repo(id: repoId), matching: [glob], progressHandler: progressHandler)  // Utilisation de Hub.Repo
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
        
        throw Hub.HubClientError.unexpectedError
    }
    
    func getFileMetadata(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [FileMetadata] {  // Utilisation de Hub.Repo
        // Pour notre modèle FuseChat spécifique, retourner des métadonnées factices
        if repo.id == HubApi.cloudflareModelId {
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
        
        throw Hub.HubClientError.unexpectedError
    }
    
    func getFileMetadata(from repoId: String, matching globs: [String] = []) async throws -> [FileMetadata] {
        return try await getFileMetadata(from: Hub.Repo(id: repoId), matching: globs)  // Utilisation de Hub.Repo
    }
    
    func getFileMetadata(from repo: Hub.Repo, matching glob: String) async throws -> [FileMetadata] {  // Utilisation de Hub.Repo
        return try await getFileMetadata(from: repo, matching: [glob])
    }
    
    func getFileMetadata(from repoId: String, matching glob: String) async throws -> [FileMetadata] {
        return try await getFileMetadata(from: Hub.Repo(id: repoId), matching: [glob])  // Utilisation de Hub.Repo
    }
}

/// Stateless wrappers that use `HubApi` instances
public extension Hub {
    static func getFilenames(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: repo, matching: globs)
    }
    
    static func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: Hub.Repo(id: repoId), matching: globs)  // Utilisation de Hub.Repo
    }
    
    static func getFilenames(from repo: Hub.Repo, matching glob: String) async throws -> [String] {  // Utilisation de Hub.Repo
        return try await HubApi.shared.getFilenames(from: repo, matching: glob)
    }
    
    static func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: Hub.Repo(id: repoId), matching: glob)  // Utilisation de Hub.Repo
    }
    
    static func snapshot(from repo: Hub.Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: repo, matching: globs, progressHandler: progressHandler)
    }
    
    static func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: Hub.Repo(id: repoId), matching: globs, progressHandler: progressHandler)  // Utilisation de Hub.Repo
    }
    
    static func snapshot(from repo: Hub.Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: repo, matching: glob, progressHandler: progressHandler)
    }
    
    static func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: Hub.Repo(id: repoId), matching: glob, progressHandler: progressHandler)  // Utilisation de Hub.Repo
    }
    
    static func getFileMetadata(fileURL: URL) async throws -> HubApi.FileMetadata {
        return try await HubApi.shared.getFileMetadata(url: fileURL)
    }
    
    static func getFileMetadata(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [HubApi.FileMetadata] {
        return try await HubApi.shared.getFileMetadata(from: repo, matching: globs)
    }
    
    static func getFileMetadata(from repoId: String, matching globs: [String] = []) async throws -> [HubApi.FileMetadata] {
        return try await HubApi.shared.getFileMetadata(from: Hub.Repo(id: repoId), matching: globs)  // Utilisation de Hub.Repo
    }
    
    static func getFileMetadata(from repo: Hub.Repo, matching glob: String) async throws -> [HubApi.FileMetadata] {
        return try await HubApi.shared.getFileMetadata(from: repo, matching: [glob])
    }
    
    static func getFileMetadata(from repoId: String, matching glob: String) async throws -> [HubApi.FileMetadata] {
        return try await HubApi.shared.getFileMetadata(from: Hub.Repo(id: repoId), matching: [glob])  // Utilisation de Hub.Repo
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
