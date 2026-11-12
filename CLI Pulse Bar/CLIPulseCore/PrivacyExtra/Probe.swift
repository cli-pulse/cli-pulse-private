import Darwin

public func probe(_ path: UnsafePointer<CChar>) -> Int32 {
    var value = statfs()
    return statfs(path, &value)
}
