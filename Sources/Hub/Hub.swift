import Foundation
import Hub

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

public class LanguageModelConfigurationFromHub {
  struct Configurations {
      var modelConfig: Hub.Config
      var tokenizerConfig: Hub.Config?
      var tokenizerData: Hub.Config
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

  public var modelConfig: Hub.Config {
      get async throws {
          try await configPromise!.value.modelConfig
      }
  }

  public var tokenizerConfig: Hub.Config? {
      get async throws {
          if let hubConfig = try await configPromise!.value.tokenizerConfig {
              if let _ = hubConfig.tokenizerClass?.stringValue { return hubConfig }
              guard let modelType = try await modelType else { return hubConfig }

              if let fallbackConfig = Self.fallbackTokenizerConfig(for: modelType) {
                  let configuration = fallbackConfig.dictionary.merging(hubConfig.dictionary, uniquingKeysWith: { current, _ in current })
                  return Hub.Config(configuration)
              }

              var configuration = hubConfig.dictionary
              configuration["tokenizer_class"] = "\(modelType.capitalized)Tokenizer"
              return Hub.Config(configuration)
          }

          guard let modelType = try await modelType else { return nil }
          return Self.fallbackTokenizerConfig(for: modelType)
      }
  }

  public var tokenizerData: Hub.Config {
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
              tokenizerConfig = Hub.Config(configDict)
          } else {
              tokenizerConfig = Hub.Config(["chat_template": chatTemplate])
          }
      }
      
      return Configurations(
          modelConfig: modelConfig,
          tokenizerConfig: tokenizerConfig,
          tokenizerData: tokenizerData
      )
  }

  static func fallbackTokenizerConfig(for modelType: String) -> Hub.Config? {
      guard let url = Bundle.module.url(forResource: "\(modelType)_tokenizer_config", withExtension: "json") else { return nil }
      do {
          let data = try Data(contentsOf: url)
          let parsed = try JSONSerialization.jsonObject(with: data, options: [])
          guard let dictionary = parsed as? [NSString: Any] else { return nil }
          return Hub.Config(dictionary)
      } catch {
          return nil
      }
  }
}


