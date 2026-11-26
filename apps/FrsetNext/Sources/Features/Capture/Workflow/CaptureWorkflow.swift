import AppKit
import Foundation
import Security

// MARK: - 自定义工作流（v264 · C 档「工作流 + GitHub/Linear」）
//
// 对标 1Capture 的「截图后自动执行一串动作」。这里不做可视化编排器，
// 而是「一张有序步骤表」——90% 的真实需求就是：
//   保存到某处 → 识别文字 → 上传图床拿 URL → 建一个 GitHub / Linear issue
//
// 关键设计：
//   · 步骤之间用**上下文**传递产物（文件 → 文本 → 图片 URL），后面的步骤能引用前面的结果；
//   · 模板占位符 {name} {text} {url} {date}，写在标题/正文里；
//   · GitHub / Linear 凭证由 Keychain 保存；JSON 仅保存工作流配置。

public struct WorkflowStep: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case save, copy, ocr, pin, upload, github, linear
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .save:   return "保存到文件夹"
            case .copy:   return "复制到剪贴板"
            case .ocr:    return "识别文字"
            case .pin:    return "钉在屏幕上"
            case .upload: return "上传图片（自建 / 图床）"
            case .github: return "新建 GitHub Issue"
            case .linear: return "新建 Linear Issue"
            }
        }
        /// 两个参数输入框的标题
        public var fieldTitles: (String, String)? {
            switch self {
            case .save:   return ("文件夹路径", "")
            case .upload: return ("上传地址（multipart）", "文件字段名（默认 file）")
            case .github: return ("仓库 owner/repo", "GitHub Token")
            case .linear: return ("Team ID", "Linear API Key")
            default:      return nil
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    public var a: String = ""
    public var b: String = ""

    public init(kind: Kind, a: String = "", b: String = "") {
        self.kind = kind
        self.a = a
        self.b = b
    }
}

public struct CaptureWorkflow: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var enabled: Bool
    public var steps: [WorkflowStep]

    public init(name: String, enabled: Bool = false, steps: [WorkflowStep] = []) {
        self.name = name
        self.enabled = enabled
        self.steps = steps
    }
}

// MARK: - 存储

public enum WorkflowStore {

    private static let credentialService = "com.sxyq.frsetnext.capture-workflow"

    private static var fileURL: URL {
        AppDirectories.sub("workflows").appendingPathComponent("workflows.json")
    }

    public static func load() -> [CaptureWorkflow] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([CaptureWorkflow].self, from: data) else {
            return seed
        }
        var list = stored
        var migrated = false
        var migrationComplete = true
        for workflowIndex in list.indices {
            for stepIndex in list[workflowIndex].steps.indices {
                let workflow = list[workflowIndex]
                let step = workflow.steps[stepIndex]
                guard step.kind == .github || step.kind == .linear else { continue }
                let account = credentialAccount(workflow: workflow, step: step)
                do {
                    if let credential = try readCredential(account: account) {
                        list[workflowIndex].steps[stepIndex].b = credential
                        if !step.b.isEmpty { migrated = true }
                    } else if !step.b.isEmpty {
                        try writeCredential(step.b, account: account)
                        migrated = true
                    }
                } catch {
                    migrationComplete = false
                    Log.error("Workflow", "Keychain 凭证读取或迁移失败：\(error.localizedDescription)")
                }
            }
        }
        if migrated, migrationComplete, save(list) == nil { return list }
        return list
    }

    @discardableResult
    public static func save(_ list: [CaptureWorkflow]) -> String? {
        do {
            var sanitized = list
            var retainedCredentials = Set<String>()
            for workflowIndex in list.indices {
                for stepIndex in list[workflowIndex].steps.indices {
                    let workflow = list[workflowIndex]
                    let step = workflow.steps[stepIndex]
                    guard step.kind == .github || step.kind == .linear else { continue }
                    let account = credentialAccount(workflow: workflow, step: step)
                    if !step.b.isEmpty {
                        try writeCredential(step.b, account: account)
                        retainedCredentials.insert(account)
                    }
                    sanitized[workflowIndex].steps[stepIndex].b = ""
                }
            }
            let old = (try? Data(contentsOf: fileURL)).flatMap {
                try? JSONDecoder().decode([CaptureWorkflow].self, from: $0)
            } ?? []
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sanitized)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            for workflow in old {
                for step in workflow.steps where step.kind == .github || step.kind == .linear {
                    let account = credentialAccount(workflow: workflow, step: step)
                    if !retainedCredentials.contains(account) { try deleteCredential(account: account) }
                }
            }
            return nil
        } catch {
            Log.error("Workflow", "保存工作流失败：\(error.localizedDescription)")
            return "保存工作流失败：\(error.localizedDescription)"
        }
    }

    private static func credentialAccount(workflow: CaptureWorkflow, step: WorkflowStep) -> String {
        "\(workflow.id.uuidString).\(step.id.uuidString).\(step.kind.rawValue)"
    }

    private static func readCredential(account: String) throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: credentialService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }

    private static func writeCredential(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: credentialService,
                                    kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func deleteCredential(account: String) throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword,
                                    kSecAttrService: credentialService,
                                    kSecAttrAccount: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// 首次进入时给一条**禁用**的示例，让用户知道步骤长什么样
    private static var seed: [CaptureWorkflow] {
        [CaptureWorkflow(name: "示例：保存 + 识别 + 复制",
                         enabled: false,
                         steps: [WorkflowStep(kind: .save, a: RecordingOptions.saveDirectory.path),
                                 WorkflowStep(kind: .ocr),
                                 WorkflowStep(kind: .copy)])]
    }
}

// MARK: - 执行

public final class CaptureWorkflowRunner {

    public static let shared = CaptureWorkflowRunner()

    private let queue = DispatchQueue(label: "kitnest.workflow", qos: .utility)
    private let pendingLock = NSLock()
    private var pendingJobs = 0
    private let maximumPendingJobs = 3

    private init() {}

    /// 截图落盘后调用（App 层接线）。只在有启用工作流时才做任何事。
    public func imageCaptured(url: URL, data: Data) {
        pendingLock.lock()
        guard pendingJobs < maximumPendingJobs else {
            pendingLock.unlock()
            DispatchQueue.main.async {
                Toast.show("截图工作流队列已满，截图已保留但未执行工作流", icon: "exclamationmark.triangle", isWarning: true)
            }
            return
        }
        pendingJobs += 1
        pendingLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.pendingLock.lock()
                self.pendingJobs -= 1
                self.pendingLock.unlock()
            }
            let workflows = WorkflowStore.load().filter { $0.enabled && !$0.steps.isEmpty }
            for workflow in workflows {
                if let failure = self.run(workflow, url: url, data: data) {
                    self.presentFailure(failure)
                }
            }
        }
    }

    // MARK: 上下文

    private struct Context {
        var fileURL: URL
        var text: String = ""
        var uploadedURL: String = ""
        var name: String
    }

    private struct StepFailure {
        let workflow: CaptureWorkflow
        let stepIndex: Int
        let context: Context
        let url: URL
        let data: Data
        let message: String
    }

    private func run(_ workflow: CaptureWorkflow, url: URL, data: Data,
                     from startIndex: Int = 0, context: Context? = nil) -> StepFailure? {
        var ctx = context ?? Context(fileURL: url, name: url.deletingPathExtension().lastPathComponent)
        Log.info("Workflow", "开始执行「\(workflow.name)」（\(workflow.steps.count) 步）")
        for (index, step) in workflow.steps.enumerated().dropFirst(startIndex) {
            do {
                try perform(step, data: data, ctx: &ctx)
            } catch {
                Log.error("Workflow", "「\(workflow.name)」步骤 \(step.kind.rawValue) 失败：\(error.localizedDescription)")
                return StepFailure(workflow: workflow, stepIndex: index, context: ctx,
                                   url: url, data: data, message: error.localizedDescription)
            }
        }
        Log.info("Workflow", "「\(workflow.name)」结束（文本 \(ctx.text.count) 字，URL=\(ctx.uploadedURL.isEmpty ? "无" : "有")）")
        return nil
    }

    private func presentFailure(_ failure: StepFailure) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "工作流「\(failure.workflow.name)」在「\(failure.workflow.steps[failure.stepIndex].kind.title)」失败"
            alert.informativeText = "\(failure.message)\n截图保留在：\(failure.url.path)"
            alert.addButton(withTitle: "重试此步骤")
            alert.addButton(withTitle: "关闭")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.queue.async {
                if let next = self.run(failure.workflow, url: failure.url, data: failure.data,
                                       from: failure.stepIndex, context: failure.context) {
                    self.presentFailure(next)
                }
            }
        }
    }

    private func perform(_ step: WorkflowStep, data: Data, ctx: inout Context) throws {
        switch step.kind {
        case .save:
            let dir = URL(fileURLWithPath: (step.a as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(ctx.fileURL.lastPathComponent)
            if dest.standardizedFileURL != ctx.fileURL.standardizedFileURL {
                let temporary = dir.appendingPathComponent(".\(UUID().uuidString).\(dest.lastPathComponent)")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: ctx.fileURL, to: temporary)
                if FileManager.default.fileExists(atPath: dest.path) {
                    _ = try FileManager.default.replaceItemAt(dest, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: dest)
                }
            }
        case .copy:
            let pasteboard = NSPasteboard.general
            DispatchQueue.main.sync {
                pasteboard.clearContents()
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
            }
        case .ocr:
            let text = try recognizeText(data: data)
            ctx.text = text
        case .pin:
            guard let cg = ImageProcessor.cgImage(from: ctx.fileURL) else {
                throw NSError(domain: "Workflow", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "无法读取截图图片"])
            }
            DispatchQueue.main.sync {
                PinnedScreenshotManager.shared.show(image: cg)
            }
        case .upload:
            let endpoint = step.a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty, let url = URL(string: endpoint),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw NSError(domain: "Workflow", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: "上传地址无效"])
            }
            let field = step.b.isEmpty ? "file" : step.b
            let remote = try upload(data: data, to: url, field: field, filename: ctx.fileURL.lastPathComponent)
            ctx.uploadedURL = remote
        case .github:
            let repo = step.a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repo.isEmpty, !step.b.isEmpty else {
                throw NSError(domain: "Workflow", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "请填写仓库和 GitHub Token"])
            }
            try createGitHubIssue(repo: repo, token: step.b, ctx: ctx)
        case .linear:
            let team = step.a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !team.isEmpty, !step.b.isEmpty else {
                throw NSError(domain: "Workflow", code: 8,
                              userInfo: [NSLocalizedDescriptionKey: "请填写 Team ID 和 Linear API Key"])
            }
            try createLinearIssue(teamID: team, key: step.b, ctx: ctx)
        }
    }

    // MARK: OCR

    private func recognizeText(data: Data) throws -> String {
        let sem = DispatchSemaphore(value: 0)
        var result = ""
        var failure: Error?
        Task {
            do {
                result = try await OCRService.shared.recognizeText(imageData: data, quality: .fast)
            } catch {
                failure = error
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 20) == .timedOut {
            throw NSError(domain: "Workflow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "识别超时"])
        }
        if let failure { throw failure }
        return result
    }

    // MARK: 上传

    private func upload(data: Data, to endpoint: URL, field: String, filename: String) throws -> String {
        let boundary = "----Kitnest\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let (responseData, response) = try synchronousRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Workflow", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "上传返回 \(code)"])
        }
        // 常见返回：{ "url": "..." } / { "data": { "url": "..." } } / { "data": [{ "url": "..." }] }
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if let url = json["url"] as? String { return url }
            if let data = json["data"] as? [String: Any], let url = data["url"] as? String { return url }
            if let data = json["data"] as? [[String: Any]],
               let first = data.first, let url = first["url"] as? String { return url }
        }
        throw NSError(domain: "Workflow", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "上传响应里没有 url 字段"])
    }

    // MARK: GitHub / Linear

    private func createGitHubIssue(repo: String, token: String, ctx: Context) throws {
        // 2026-11-25（二轮复核）：repo 是用户输入，含空格/非法字符时 URL(string:) 返回 nil，
        // 后台队列强解包直接崩。改为失败时把错误回传给调用方。
        guard let url = URL(string: "https://api.github.com/repos/\(repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo)/issues") else {
            throw NSError(domain: "Workflow", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub 仓库地址无法构造 URL：\(repo)"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "title": template(self.defaultTitle, ctx: ctx),
            "body": template(self.defaultBody, ctx: ctx),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try synchronousRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "Workflow", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub \(code) \(body)"])
        }
    }

    private func createLinearIssue(teamID: String, key: String, ctx: Context) throws {
        let query = """
        mutation CreateIssue($teamId: String!, $title: String!, $description: String!) {
          issueCreate(input: { teamId: $teamId, title: $title, description: $description }) {
            success
          }
        }
        """
        let payload: [String: Any] = [
            "query": query,
            "variables": [
                "teamId": teamID,
                "title": template(defaultTitle, ctx: ctx),
                "description": template(defaultBody, ctx: ctx),
            ],
        ]
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try synchronousRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "Workflow", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Linear \(code)"])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let errors = json?["errors"] as? [[String: Any]], let first = errors.first {
            throw NSError(domain: "Workflow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Linear: \(first["message"] ?? "")"])
        }
        guard let payload = json?["data"] as? [String: Any],
              let issue = payload["issueCreate"] as? [String: Any],
              issue["success"] as? Bool == true else {
            throw NSError(domain: "Workflow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Linear 未能创建 Issue"])
        }
    }

    private var defaultTitle: String { "截图：{name}" }

    private var defaultBody: String {
        """
        来自 Kitnest 的截图。

        文件：{name}
        图片：{url}
        时间：{date}

        ---
        {text}
        """
    }

    private func template(_ raw: String, ctx: Context) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = raw
        out = out.replacingOccurrences(of: "{name}", with: ctx.name)
        out = out.replacingOccurrences(of: "{text}", with: ctx.text)
        out = out.replacingOccurrences(of: "{url}", with: ctx.uploadedURL.isEmpty ? "（未上传）" : ctx.uploadedURL)
        out = out.replacingOccurrences(of: "{date}", with: fmt.string(from: Date()))
        return out
    }

    // MARK: 同步 HTTP（工作流跑在后台队列，用信号量等异步任务最直白）

    private func synchronousRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        var result: (Data, URLResponse)?
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            if let data, let response { result = (data, response) }
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + 30) == .timedOut {
            throw NSError(domain: "Workflow", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "网络请求超时"])
        }
        if let failure { throw failure }
        guard let result else {
            throw NSError(domain: "Workflow", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "网络请求没有返回"])
        }
        return result
    }
}
