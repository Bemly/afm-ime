import Foundation

/// dict.bin v1 二进制格式(全部小端)。
/// 布局: [Header 48B][Offsets u64 × recordCount][Syllable blob][Records]
/// Records 按 (key 字节序, weight 降序, word 字节序) 排列,使每个 key 的记录连续且按词频降序。
public enum DictFormat {
    public static let magic: UInt32 = 0x444D4641 // "AFMD" little-endian
    public static let version: UInt32 = 1
    public static let headerSize = 40

    // Header 字段偏移
    static let offMagic = 0
    static let offVersion = 4
    static let offRecordCount = 8
    static let offOffsetsOffset = 16
    static let offSyllableCount = 24
    static let offSyllablesOffset = 32

    public struct Record {
        public var keyStart: Int
        public var keyLen: Int
        public var wordStart: Int
        public var wordLen: Int
        public var weight: UInt32
    }
}
