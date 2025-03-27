import Foundation

public struct Hub {
    enum HubClientError: Error {
        case unexpectedError
    }
    
    func loadConfig(modelFolder: URL) async throws -> Configuration {
        let configPath = modelFolder.appendingPathComponent("config.json")
        let tokenizerConfigPath = modelFolder.appendingPathComponent("tokenizer_config.json") 
        let tokenizerPath = modelFolder.appendingPathComponent("tokenizer.json")
        
        guard FileManager.default.fileExists(atPath: configPath.path),
              FileManager.default.fileExists(atPath: tokenizerPath.path) else {
            throw HubClientError.unexpectedError
        }
        
        // Add this function in Hub
        func configuration(fileURL: URL) throws -> Config {
            let data = try Data(contentsOf: fileURL)
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = parsed as? [NSString: Any] else {
                throw HubClientError.unexpectedError
            }
            return Config(dictionary)
        }
        
        let modelConfig = try configuration(fileURL: configPath)
        let tokenizerData = try configuration(fileURL: tokenizerPath)
        let tokenizerConfig = try? configuration(fileURL: tokenizerConfigPath)
        
        return Configuration(
            modelConfig: modelConfig,
            tokenizerConfig: tokenizerConfig,
            tokenizerData: tokenizerData
        )
    }
}

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

public struct Configuration {
    public let modelConfig: Config
    public let tokenizerConfig: Config?
    public let tokenizerData: Config
}

