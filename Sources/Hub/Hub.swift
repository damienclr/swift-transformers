import Foundation

public struct Hub {}

public extension Hub {
    enum HubClientError: Error {
        case parse
        case authorizationRequired
        case unexpectedError
        case httpStatusCode(Int)
    }
    
    enum RepoType: String {
        case models
        case datasets
        case spaces
    }
    
    struct Repo {
        public let id: String
        public let type: RepoType
        
        public init(id: String, type: RepoType = .models) {
            self.id = id
            self.type = type
        }
    }
}

// The conflicting Config struct that was previously here is REMOVED.
// All references to 'Config' below will now resolve to the one from Config.txt

public class LanguageModelConfigurationFromHub {
    struct Configurations {
        var modelConfig: Config // Now refers to the main Config from Config.txt
        var tokenizerConfig: Config? // Now refers to the main Config from Config.txt
        var tokenizerData: Config // Now refers to the main Config from Config.txt
    }

    private var configPromise: Task<Configurations, Error>? = nil

    public init(
        modelName: String,
        hubApi: HubApi = .shared // Assuming HubApi is correctly using the main Config
    ) {
        self.configPromise = Task.init {
            return try await self.loadConfig(modelName: modelName, hubApi: hubApi)
        }
    }
    
    public init(
        modelFolder: URL,
        hubApi: HubApi = .shared
    ) {
        self.configPromise = Task {
            return try await self.loadConfig(modelFolder: modelFolder, hubApi: hubApi)
        }
    }

    public var modelConfig: Config {
        get async throws {
            try await configPromise!.value.modelConfig
        }
    }

    public var tokenizerConfig: Config? {
        get async throws {
            var loadedTokenizerConfig = try await configPromise!.value.tokenizerConfig

            // If tokenizerClass is already present, return the loaded config
          if let currentConfig = loadedTokenizerConfig, currentConfig.tokenizerClass != nil {
              return currentConfig
          }

            guard let modelType = try await modelType else {
                // Cannot determine modelType, return original (possibly nil or without tokenizerClass)
                return loadedTokenizerConfig
            }

            var baseDict: [String: Any] = [:]
            if let configToConvert = loadedTokenizerConfig {
                // Use toJinjaCompatible to get a dictionary representation
         if let dict = configToConvert.toJinjaCompatible() as? [String: Any] {
                  baseDict = dict
              } else if let str = configToConvert as? String { // Handle if it's just a string for some reason
                   baseDict["value"] = str // Or handle appropriately
              }
            }
            
            var effectiveDict = baseDict

            if let fallbackModelSpecificConfig = Self.fallbackTokenizerConfig(for: modelType) {
                 if let fallbackDict = fallbackModelSpecificConfig.toJinjaCompatible() as? [String: Any] {
                    // Merge: fallback provides defaults, baseDict (from file) overrides/adds.
                    // The original was: fallbackConfig.dictionary.merging(hubConfig.dictionary...)
                    // which means hubConfig (our baseDict) takes precedence for shared keys.
                    effectiveDict = fallbackDict.merging(baseDict, uniquingKeysWith: { _, newFromFile in newFromFile })
                 }
            }
            
            // Ensure tokenizer_class is set if not present after merge or if no fallback merge happened
            if effectiveDict["tokenizer_class"] == nil && !(effectiveDict["tokenizer_class"] is NSNull) {
                 effectiveDict["tokenizer_class"] = "\(modelType.capitalized)Tokenizer"
            }
            
            // Convert the dictionary back to the main Config type
            // The main Config has an init([NSString: Any]) which uses convertToBinaryDistinctKeys internally.
            // We need to ensure values are appropriate. convertToBinaryDistinctKeys handles nested Configs and basic types.
            let nsStringDict = Dictionary(uniqueKeysWithValues: effectiveDict.map { (NSString(string: $0.key), $0.value) })
            return Config(nsStringDict)
        }
    }

    public var tokenizerData: Config {
        get async throws {
            try await configPromise!.value.tokenizerData
        }
    }

    public var modelType: String? {
        get async throws {
            // Use the .string() method from the main Config
            try await modelConfig.modelType?.string()
        }
    }

    func loadConfig(
        modelName: String,
        hubApi: HubApi = .shared
    ) async throws -> Configurations {
        let repo = Hub.Repo(id: modelName)
        // Assuming hubApi.localRepoLocation and hubApi.configuration are compatible with the main Config
        let modelFolder = hubApi.localRepoLocation(repo)
        
        return try await loadConfig(modelFolder: modelFolder, hubApi: hubApi)
    }

    func loadConfig(
        modelFolder: URL,
        hubApi: HubApi = .shared
    ) async throws -> Configurations {
        let modelConfig = try hubApi.configuration(fileURL: modelFolder.appending(path: "config.json"))
        let tokenizerData = try hubApi.configuration(fileURL: modelFolder.appending(path: "tokenizer.json"))
        var tokenizerConfigFromFile = try? hubApi.configuration(fileURL: modelFolder.appending(path: "tokenizer_config.json"))
        
     if let chatTemplateConfig = try? hubApi.configuration(fileURL: modelFolder.appending(path: "chat_template.json")),
         let chatTemplate = chatTemplateConfig.chatTemplate { // Use direct property access
          
          var tempDict: [String: Any] = [:]
          if let currentTokenizerConfig = tokenizerConfigFromFile {
              if let dict = currentTokenizerConfig.toJinjaCompatible() as? [String: Any] {
                  tempDict = dict
              }
          }
          tempDict["chat_template"] = chatTemplate
          
          let nsStringDict = Dictionary(uniqueKeysWithValues: tempDict.map { (NSString(string: $0.key), $0.value) })
          tokenizerConfigFromFile = Config(nsStringDict) // Recreate Config with the new chat_template
      }
        
        return Configurations(
            modelConfig: modelConfig,
            tokenizerConfig: tokenizerConfigFromFile,
            tokenizerData: tokenizerData
        )
    }

    static func fallbackTokenizerConfig(for modelType: String) -> Config? {
        // This should ideally be part of the Bundle for the swift-transformers package itself.
        // Using Bundle.module assumes this code is within that package.
        guard let url = Bundle.module.url(forResource: "\(modelType)_tokenizer_config", withExtension: "json") else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dictionary = parsed as? [NSString: Any] else { return nil }
            // This will now use the main Config's initializer
            return Config(dictionary)
        } catch {
            return nil
        }
    }
}

