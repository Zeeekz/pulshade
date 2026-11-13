import Foundation

/// An erasure code for spreading a key or ciphertext over many small messages (`Ratchet`).
///
/// The data is cut into `k` blocks of `size` bytes. Chunk number `j` is a fixed mix of those blocks, taken over the
/// 256-element field GF(2^8) with a Cauchy matrix, so that ANY `k` different chunks rebuild the data, whichever they
/// are and whatever order they arrive in. A lost message costs one more message, never a restart.
enum ChunkCode {
    /// Bytes of data in each chunk.
    static let size = 96
    /// Chunk numbers run 0..<240, then start again. At most 16 blocks.
    static let numbers = 240
    static let maxBlocks = 16

    static func blocks(for length: Int) -> Int { (length + size - 1) / size }

    // GF(2^8), polynomial x^8 + x^4 + x^3 + x^2 + 1.
    private static let tables: (exp: [UInt8], log: [Int]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11d }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : tables.exp[tables.log[Int(a)] + tables.log[Int(b)]]
    }

    private static func inverse(_ a: UInt8) -> UInt8 { tables.exp[255 - tables.log[Int(a)]] }

    /// Row `j`, column `i` of the Cauchy matrix: 1 / (x_j + y_i), with x_j = j and y_i = 240 + i, which never meet.
    private static func coefficient(_ j: Int, _ i: Int) -> UInt8 { inverse(UInt8(j ^ (numbers + i))) }

    /// Chunk number `j` of `data`.
    static func chunk(_ data: Data, number j: Int) -> Data {
        let bytes = [UInt8](data)
        let k = blocks(for: bytes.count)
        precondition(k > 0 && k <= maxBlocks && j >= 0 && j < numbers)
        var out = [UInt8](repeating: 0, count: size)
        for i in 0..<k {
            let c = coefficient(j, i)
            for b in 0..<size {
                let at = i * size + b
                if at < bytes.count { out[b] ^= mul(c, bytes[at]) }
            }
        }
        return Data(out)
    }

    /// The data of `length` bytes, from any `blocks(for: length)` different chunks (number to bytes), or nil if there
    /// aren't enough or one is the wrong size.
    static func decode(_ parts: [Int: Data], length: Int) -> Data? {
        let k = blocks(for: length)
        guard k > 0, k <= maxBlocks else { return nil }
        let rows = parts.keys.filter { $0 >= 0 && $0 < numbers && parts[$0]?.count == size }.sorted().prefix(k)
        guard rows.count == k else { return nil }
        // Solve M x = p for each byte position at once: Gauss-Jordan on [M | chunks].
        var m = rows.map { j in (0..<k).map { coefficient(j, $0) } + [UInt8](parts[j]!) }
        let width = k + size
        for col in 0..<k {
            guard let pivot = (col..<k).first(where: { m[$0][col] != 0 }) else { return nil }
            m.swapAt(col, pivot)
            let inv = inverse(m[col][col])
            for c in 0..<width { m[col][c] = mul(inv, m[col][c]) }
            for r in 0..<k where r != col && m[r][col] != 0 {
                let f = m[r][col]
                for c in 0..<width { m[r][c] ^= mul(f, m[col][c]) }
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(k * size)
        for r in 0..<k { out.append(contentsOf: m[r][k...]) }
        return Data(out.prefix(length))
    }
}
