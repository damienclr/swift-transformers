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

// MARK: - Configuration files with dynamic lookup
@dynamicMemberLookup
public struct Config {
    public private(set) var dictionary: [NSString: Any]

    public init(_ dictionary: [NSString: Any]) {
        self.dictionary = dictionary
    }

    func camelCase(_ string: String) -> String {
        return string
            .split(separator: "_")
            .enumerated()
            .map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }
            .joined()
    }
    
    func uncamelCase(_ string: String) -> String {
        let scalars = string.unicodeScalars
        var result = ""
        
        var previousCharacterIsLowercase = false
        for scalar in scalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                if previousCharacterIsLowercase {
                    result += "_"
                }
                let lowercaseChar = Character(scalar).lowercased()
                result += lowercaseChar
                previousCharacterIsLowercase = false
            } else {
                result += String(scalar)
                previousCharacterIsLowercase = true
            }
        }
        
        return result
    }

    public subscript(dynamicMember member: String) -> Config? {
        let key = (dictionary[member as NSString] != nil ? member : uncamelCase(member)) as NSString
        if let value = dictionary[key] as? [NSString: Any] {
            return Config(value)
        } else if let value = dictionary[key] {
            return Config(["value": value])
        }
        return nil
    }

    public var value: Any? {
        return dictionary["value"]
    }
    
    public var intValue: Int? { value as? Int }
    public var boolValue: Bool? { value as? Bool }
    public var stringValue: String? { value as? String }
    
    public var arrayValue: [Config]? {
        guard let list = value as? [Any] else { return nil }
        return list.map { Config($0 as! [NSString : Any]) }
    }
    
    public var tokenValue: (UInt, String)? { value as? (UInt, String) }
}

public class LanguageModelConfigurationFromHub {
    struct Configurations {
        var modelConfig: Config
        var tokenizerConfig: Config?
        var tokenizerData: Config
    }

    private var configPromise: Task<Configurations, Error>? = nil

    public init(
        modelName: String,
        hubApi: HubApi = .shared
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
            if let hubConfig = try await configPromise!.value.tokenizerConfig {
                if let _ = hubConfig.tokenizerClass?.stringValue { return hubConfig }
                guard let modelType = try await modelType else { return hubConfig }

                if let fallbackConfig = Self.fallbackTokenizerConfig(for: modelType) {
                    let configuration = fallbackConfig.dictionary.merging(hubConfig.dictionary, uniquingKeysWith: { current, _ in current })
                    return Config(configuration)
                }

                var configuration = hubConfig.dictionary
                configuration["tokenizer_class"] = "\(modelType.capitalized)Tokenizer"
                return Config(configuration)
            }

            guard let modelType = try await modelType else { return nil }
            return Self.fallbackTokenizerConfig(for: modelType)
        }
    }

    public var tokenizerData: Config {
        get async throws {
            try await configPromise!.value.tokenizerData
        }
    }

    public var modelType: String? {
        get async throws {
            try await modelConfig.modelType?.stringValue
        }
    }

    func loadConfig(
        modelName: String,
        hubApi: HubApi = .shared
    ) async throws -> Configurations {
        let repo = Hub.Repo(id: modelName)
        let modelFolder = hubApi.localRepoLocation(repo)
        
        return try await loadConfig(modelFolder: modelFolder, hubApi: hubApi)
    }

    func loadConfig(
        modelFolder: URL,
        hubApi: HubApi = .shared
    ) async throws -> Configurations {
        let modelConfig = try hubApi.configuration(fileURL: modelFolder.appending(path: "config.json"))
        let tokenizerData = try hubApi.configuration(fileURL: modelFolder.appending(path: "tokenizer.json"))
        var tokenizerConfig = try? hubApi.configuration(fileURL: modelFolder.appending(path: "tokenizer_config.json"))
        
        if let chatTemplateConfig = try? hubApi.configuration(fileURL: modelFolder.appending(path: "chat_template.json")),
           let chatTemplate = chatTemplateConfig.chatTemplate?.stringValue {
            if var configDict = tokenizerConfig?.dictionary {
                configDict["chat_template"] = chatTemplate
                tokenizerConfig = Config(configDict)
            } else {
                tokenizerConfig = Config(["chat_template": chatTemplate])
            }
        }
        
        return Configurations(
            modelConfig: modelConfig,
            tokenizerConfig: tokenizerConfig,
            tokenizerData: tokenizerData
        )
    }

    static func fallbackTokenizerConfig(for modelType: String) -> Config? {
        guard let url = Bundle.module.url(forResource: "\(modelType)_tokenizer_config", withExtension: "json") else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dictionary = parsed as? [NSString: Any] else { return nil }
            return Config(dictionary)
        } catch {
            return nil
        }
    }
}

