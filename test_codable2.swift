import Foundation
public struct PetState: Codable {
    public var version: Int
    public init(version: Int = 1) { self.version = version }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }
}
let s = PetState()
let data = try! JSONEncoder().encode(s)
print(String(data: data, encoding: .utf8)!)
