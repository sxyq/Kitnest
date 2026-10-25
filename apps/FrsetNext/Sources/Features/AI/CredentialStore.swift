import Foundation
import CommonCrypto

// MARK: - 凭证存储
//
// 设计理由（重要）：
// 原作被诟病的一点是「每次读取 API Key 都会触发系统钥匙串授权弹窗」。
// 本重建**刻意避开钥匙串**，改为「应用数据目录下的 AES-256 加密文件」：
//   · 文件：$ApplicationSupport/FrsetNext/ai-credentials.bin，权限 0600（仅当前用户可读写）
//   · 主密钥：$ApplicationSupport/FrsetNext/.ai-keystore，安装时随机生成，同样 0600
//   · 派生：PBKDF2-SHA256（10 万轮，随机盐）→ 32 字节 AES-256 密钥；CBC + PKCS7 填充，随机 IV
// 安全边界说明（诚实标注）：本机其他进程若以同一用户身份读取到 keystore，理论上仍可解密，
// 因此这是「防明文落盘 + 防误备份泄漏」级别的方案，而非抗 root/恶意软件的方案；
// 相比钥匙串，它消除了授权弹窗与首次访问的系统 UI，符合重建目标。

public enum CredentialStoreError: Error, LocalizedError {
    case keyStoreUnavailable(String)
    case encryptionFailed(Int32)
    case decryptionFailed(Int32)
    case fileIO(String)

    public var errorDescription: String? {
        switch self {
        case .keyStoreUnavailable(let d): return "凭证主密钥不可用：\(d)"
        case .encryptionFailed(let c):    return "凭证加密失败（CommonCrypto 返回 \(c)）"
        case .decryptionFailed(let c):    return "凭证解密失败（CommonCrypto 返回 \(c)），可能文件已损坏，请重新填写 API Key"
        case .fileIO(let d):              return "凭证文件读写失败：\(d)"
        }
    }
}

/// 默认实现：加密文件（见上方设计理由）
public final class CredentialStore: LLMCredentialStoring {
    public static let shared = CredentialStore()

    private static let fileMagic = "FRSTCRE1"
    private static let keyFileMagic = "FRSTKEY1"
    private static let rounds: UInt32 = 100_000
    private static let derivedKeyLength = 32          // AES-256
    private static let saltLength = 16
    private static let ivLength = 16

    private let lock = NSLock()
    private let fileURL: URL
    private let keyFileURL: URL
    private var cache: [String: String]?

    public init(fileURL: URL? = nil, keyFileURL: URL? = nil) {
        let dir = AppDirectories.base
        self.fileURL = fileURL ?? dir.appendingPathComponent("ai-credentials.bin")
        self.keyFileURL = keyFileURL ?? dir.appendingPathComponent(".ai-keystore")
        load()
    }

    // MARK: - LLMCredentialStoring

    public func credential(for provider: LLMProviderKind) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache?[provider.rawValue]
    }

    public func setCredential(_ value: String?, for provider: LLMProviderKind) {
        lock.lock()
        var dict = cache ?? [:]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { dict.removeValue(forKey: provider.rawValue) }
        else { dict[provider.rawValue] = trimmed }
        cache = dict
        do {
            try persist(dict)
        } catch {
            Log.error("Credential", "写入凭证失败：\(error.localizedDescription)")
        }
        lock.unlock()
    }

    public func removeCredential(for provider: LLMProviderKind) {
        setCredential(nil, for: provider)
    }

    public func clear() {
        lock.lock()
        cache = [:]
        try? persist([:])
        lock.unlock()
    }

    /// 已配置凭证的厂商列表（设置页展示用）
    public func configuredProviders() -> [LLMProviderKind] {
        lock.lock(); defer { lock.unlock() }
        let keys = Set((cache ?? [:]).keys)
        return LLMProviderKind.allCases.filter { keys.contains($0.rawValue) }
    }

    // MARK: - 持久化

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = [:]
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            cache = try Self.decryptEnvelope(data, keyFileURL: keyFileURL)
        } catch {
            Log.error("Credential", "读取凭证失败：\(error.localizedDescription)")
            // 解析失败不覆盖既有文件（避免误删用户数据），下次写入时才重建
            cache = [:]
        }
    }

    private func persist(_ dict: [String: String]) throws {
        let data = try Self.encryptEnvelope(dict, keyFileURL: keyFileURL)
        try data.write(to: fileURL, options: .atomic)
        try ensureFileProtection(fileURL)
    }

    private func ensureFileProtection(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - 加解密（AES-256-CBC + PBKDF2）

    // v126（性能审计 F0154）：masterSecret 内存缓存。
    // 原实现每次 encrypt/decrypt 都从磁盘读 keystore + 剥文件头（persist/load 都各走一次），
    // 凭证保存是设置页主线程动作。密钥文件创建后不再变化，进程内缓存一次即可
    //（测试多实例按 keyFileURL 分别缓存，互不影响）。
    private static let secretLock = NSLock()
    private static var secretCache: [String: Data] = [:]

    /// 主密钥：首次使用时随机生成并落盘（0600）
    private static func masterSecret(keyFileURL: URL) throws -> Data {
        secretLock.lock()
        if let cached = secretCache[keyFileURL.path] {
            secretLock.unlock()
            return cached
        }
        secretLock.unlock()
        let secret = try loadMasterSecret(keyFileURL: keyFileURL)
        secretLock.lock()
        secretCache[keyFileURL.path] = secret
        secretLock.unlock()
        return secret
    }

    private static func loadMasterSecret(keyFileURL: URL) throws -> Data {
        if FileManager.default.fileExists(atPath: keyFileURL.path) {
            let raw = try Data(contentsOf: keyFileURL)
            if raw.count > keyFileMagic.utf8.count,
               String(data: raw.prefix(keyFileMagic.utf8.count), encoding: .utf8) == keyFileMagic {
                return raw.dropFirst(keyFileMagic.utf8.count)
            }
            // 旧格式：直接当随机串用
            return raw
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        randomFill(&bytes, 32)
        var out = Data(keyFileMagic.utf8)
        out.append(contentsOf: bytes)
        try out.write(to: keyFileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
        return Data(bytes)
    }

    private static func derivedKey(salt: Data, keyFileURL: URL) throws -> Data {
        let secret = try masterSecret(keyFileURL: keyFileURL)
        var key = [UInt8](repeating: 0, count: derivedKeyLength)
        // 再拼一段固定的应用常量：即便 keystore 被替换，也不能形成可直接复用的通用密钥
        let material = secret + Data("FrsetNext.credential.v1".utf8)
        let rc = material.withUnsafeBytes { buf -> Int32 in
            salt.withUnsafeBytes { saltBuf -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    buf.baseAddress?.assumingMemoryBound(to: Int8.self),
                    material.count,
                    saltBuf.baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    &key,
                    derivedKeyLength
                )
            }
        }
        guard rc == kCCSuccess else { throw CredentialStoreError.encryptionFailed(rc) }
        return Data(key)
    }

    private static func encryptEnvelope(_ dict: [String: String], keyFileURL: URL) throws -> Data {
        let plain = try JSONSerialization.data(withJSONObject: dict, options: [])
        let salt = try randomBytes(saltLength)
        let iv = try randomBytes(ivLength)
        let key = try derivedKey(salt: salt, keyFileURL: keyFileURL)

        let bufferSize = plain.count + kCCBlockSizeAES128 * 2
        var cipher = [UInt8](repeating: 0, count: bufferSize)
        var moved = 0
        let rc = key.withUnsafeBytes { keyBuf -> Int32 in
            iv.withUnsafeBytes { ivBuf -> Int32 in
                plain.withUnsafeBytes { plainBuf -> Int32 in
                    CCCrypt(CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            plainBuf.baseAddress, plain.count,
                            &cipher, bufferSize,
                            &moved)
                }
            }
        }
        guard rc == kCCSuccess else { throw CredentialStoreError.encryptionFailed(rc) }

        var out = Data(fileMagic.utf8)
        out.append(salt)
        out.append(iv)
        out.append(contentsOf: cipher.prefix(moved))
        return out
    }

    private static func decryptEnvelope(_ data: Data, keyFileURL: URL) throws -> [String: String] {
        let header = fileMagic.utf8.count
        guard data.count > header + saltLength + ivLength,
              String(data: data.prefix(header), encoding: .utf8) == fileMagic else {
            throw CredentialStoreError.decryptionFailed(-1)
        }
        let salt = data.dropFirst(header).prefix(saltLength)
        let iv = data.dropFirst(header + saltLength).prefix(ivLength)
        let cipher = data.dropFirst(header + saltLength + ivLength)
        let key = try derivedKey(salt: salt, keyFileURL: keyFileURL)

        var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128 * 2)
        var moved = 0
        let rc = key.withUnsafeBytes { keyBuf -> Int32 in
            iv.withUnsafeBytes { ivBuf -> Int32 in
                cipher.withUnsafeBytes { cipherBuf -> Int32 in
                    CCCrypt(CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            cipherBuf.baseAddress, cipher.count,
                            &plain, plain.count,
                            &moved)
                }
            }
        }
        guard rc == kCCSuccess else { throw CredentialStoreError.decryptionFailed(rc) }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(plain.prefix(moved))),
              let dict = obj as? [String: String] else {
            throw CredentialStoreError.decryptionFailed(-2)
        }
        return dict
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        randomFill(&bytes, count)
        return Data(bytes)
    }

    /// 系统 CSPRNG（Darwin arc4random_buf，等价于 CommonCrypto 的 CCRandomGenerateBytes）
    private static func randomFill(_ buffer: UnsafeMutableRawPointer, _ count: Int) {
        arc4random_buf(buffer, count)
    }
}

// MARK: - 内存实现（单元测试 / SwiftUI 预览用，不落盘）

public final class InMemoryCredentialStore: LLMCredentialStoring {
    private let lock = NSLock()
    private var dict: [String: String] = [:]

    public init(_ initial: [LLMProviderKind: String] = [:]) {
        for (k, v) in initial { dict[k.rawValue] = v }
    }

    public func credential(for provider: LLMProviderKind) -> String? {
        lock.lock(); defer { lock.unlock() }
        return dict[provider.rawValue]
    }
    public func setCredential(_ value: String?, for provider: LLMProviderKind) {
        lock.lock()
        if let v = value, !v.isEmpty { dict[provider.rawValue] = v }
        else { dict.removeValue(forKey: provider.rawValue) }
        lock.unlock()
    }
    public func removeCredential(for provider: LLMProviderKind) { setCredential(nil, for: provider) }
    public func clear() { lock.lock(); dict = [:]; lock.unlock() }
}
