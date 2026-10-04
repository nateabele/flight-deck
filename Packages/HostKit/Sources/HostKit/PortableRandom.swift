import Foundation
#if canImport(Glibc)
import Glibc
#endif

public enum PortableRandom {
    /// OS entropy (`getentropy` on glibc, `arc4random_buf` on Darwin), so pairing secrets
    /// never depend on Security.framework (absent on Linux). `getentropy` caps a call at 256
    /// bytes and fails with EIO beyond that, hence the chunking. It only fails on a broken
    /// kernel; returning weak bytes instead would mint a guessable secret, so we trap.
    public static func bytes(_ n: Int) -> Data {
        var out = Data()
        out.reserveCapacity(n)
        while out.count < n {
            let chunk = min(256, n - out.count)
            var buf = [UInt8](repeating: 0, count: chunk)
            #if canImport(Glibc)
            guard getentropy(&buf, chunk) == 0 else { fatalError("getentropy failed: errno \(errno)") }
            #else
            // Darwin's Swift module does not export getentropy; arc4random_buf is the same
            // kernel CSPRNG and cannot fail.
            arc4random_buf(&buf, chunk)
            #endif
            out.append(contentsOf: buf)
        }
        return out
    }
}
