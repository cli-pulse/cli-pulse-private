import Foundation
public struct PetState: Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var ownedForms: [String]
    public var ownedDayKeys: [String: String]
    public var activeForm: String?
    public var lastHatchDayKey: String?

    public init(version: Int = PetState.currentVersion,
                ownedForms: [String] = [],
                ownedDayKeys: [String: String] = [:],
                activeForm: String? = nil,
                lastHatchDayKey: String? = nil) {
        self.version = version
        self.ownedForms = ownedForms
        self.ownedDayKeys = ownedDayKeys
        self.activeForm = activeForm
        self.lastHatchDayKey = lastHatchDayKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PetState.currentVersion
        ownedForms = try c.decodeIfPresent([String].self, forKey: .ownedForms) ?? []
        ownedDayKeys = try c.decodeIfPresent([String: String].self, forKey: .ownedDayKeys) ?? [:]
        activeForm = try c.decodeIfPresent(String.self, forKey: .activeForm)
        lastHatchDayKey = try c.decodeIfPresent(String.self, forKey: .lastHatchDayKey)
    }
}
let s = PetState(ownedForms: ["foo"])
let data = try! JSONEncoder().encode(s)
print(String(data: data, encoding: .utf8)!)
