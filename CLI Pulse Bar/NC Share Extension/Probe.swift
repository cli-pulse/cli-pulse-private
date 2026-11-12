import Foundation
func ncFreeBytes(_ p: String) -> Int64 {
    var s = statfs()
    _ = statfs(p, &s)
    return Int64(s.f_bavail)
}
