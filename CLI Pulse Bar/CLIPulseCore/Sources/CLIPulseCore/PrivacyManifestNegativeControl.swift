import Foundation

// [NC, do not merge] 1.63 A3 negative control: an undeclared DiskSpace API.
enum PrivacyManifestNegativeControl {
    static func freeBytes(_ path: String) -> Int64 {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return -1 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}
