public func fourCC(_ s: String) -> UInt32 {
    precondition(s.utf8.count == 4, "FourCharCode must be 4 ASCII bytes")
    return s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
