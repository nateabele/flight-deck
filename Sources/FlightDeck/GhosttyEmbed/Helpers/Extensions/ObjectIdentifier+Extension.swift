// Adapted from ghostty v1.3.1: macos/Sources/Helpers/Extensions/ObjectIdentifier+Extension.swift
import Foundation

extension ObjectIdentifier {
    var hexString: String {
        String(UInt(bitPattern: self), radix: 16)
    }
}
