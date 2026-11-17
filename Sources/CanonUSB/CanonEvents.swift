import Foundation

/// Parsing of Canon EOS GetEvent replies.
public enum CanonEvents {
    /// "Property value changed" record type.
    static let propertyChanged: UInt32 = 0xC189

    /// Property values reported in a GetEvent reply: a list of records, each
    /// u32 size, u32 type, then data; type 0xC189 carries u32 property, u32
    /// value. Stops at a record that is too short or runs past the end.
    public static func propertyValues(in data: Data) -> [UInt32: UInt32] {
        var values: [UInt32: UInt32] = [:]
        data.withUnsafeBytes { raw in
            func u32(_ offset: Int) -> UInt32 {
                raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
            var offset = 0
            while offset + 8 <= raw.count {
                let size = Int(u32(offset))
                guard size >= 8, offset + size <= raw.count else { break }
                if u32(offset + 4) == propertyChanged && size >= 16 {
                    values[u32(offset + 8)] = u32(offset + 12)
                }
                offset += size
            }
        }
        return values
    }
}

/// The camera's battery level, as Canon EOS bodies report it (property 0xD111).
public enum BatteryLevel: Equatable {
    case low, quarter, half, threeQuarters, full

    public init?(canonValue: UInt32) {
        switch canonValue {
        case 0: self = .low
        case 5: self = .quarter
        case 1: self = .half
        case 4: self = .threeQuarters
        case 2: self = .full
        default: return nil
        }
    }

    public var text: String {
        switch self {
        case .low: return "Low"
        case .quarter: return "25%"
        case .half: return "50%"
        case .threeQuarters: return "75%"
        case .full: return "100%"
        }
    }
}
