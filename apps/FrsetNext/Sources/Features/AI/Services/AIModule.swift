import Foundation
import SwiftUI

// MARK: - AI 模块入口
//
// 由总控在 App 层调用 `AIModule.start()`（或统一走 ModuleRegistry.startAll()）。
// 启动动作：重建门面 → 注入 ServiceLocator → 注册面板区段与设置页签。

public enum AIModule: AppModule {
    public static let identifier = "ai"

    public static func start() {
        // 0) 旧版（Gemini-only）配置一次性迁移：必须在重建门面之前完成，
        //    否则会先按旧偏好加载一次适配器。迁移带台账，重启不会重复执行。
        //
        // 2026-11-26 修复（二轮 low）：migrateIfNeeded 首次会触达 CredentialStore →
        // PBKDF2(10 万轮) + AES，属启动主线程同步阻塞（旧配置存在时还要再写一次凭证）。
        // 现在整段迁移挪到后台，完成后回主线程重建门面；ServiceLocator 先注入同一个门面
        // 对象（LLMService.shared 本身已存在，reload 只重建内部适配器），注入不再被迁移拖住。
        ServiceLocator.llmService = LLMService.shared

        DispatchQueue.global(qos: .userInitiated).async {
            LegacyGeminiMigrator.shared.migrateIfNeeded()
            // 顺手把凭证解密预热掉，避免用户首次打开 AI 面板时才吃到一次性解密
            _ = CredentialStore.shared.credential(for: AISettings.providerKind)
            DispatchQueue.main.async {
                // 1) 依据偏好重建当前厂商/模型
                LLMService.shared.reload()
                Log.info("AI", "AI 模块已启动（厂商：\(AISettings.providerKind.displayName) 模型：\(LLMService.shared.currentModel)）")
            }
        }

        // 2) 主面板区段（供 04 面板模块渲染）
        PanelSectionRegistry.register(PanelSectionDescriptor(
            id: "ai", title: "AI", priority: 40,
            build: { AnyView(AISectionView()) }))

        // 3) 设置窗口页签（供 07 设置模块渲染）
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "ai", title: "AI", systemImage: "sparkles"))

        // 4) 登记到模块表（重复注册会被去重，便于总控统一 startAll）
        ModuleRegistry.register(AIModule.self)
    }
}
