import Foundation
let d = FileManager.default.temporaryDirectory
let url = d.appendingPathComponent("doesnotexist.txt")
let tmp = d.appendingPathComponent("tmp.txt")
try! Data("hello".utf8).write(to: tmp)
do {
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    print("success")
} catch {
    print("error: \(error)")
}
