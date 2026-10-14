import SwiftUI
import Combine

// MARK: - @State 兼容层
//
// 成因：本机只有 Command Line Tools（无完整 Xcode），工具链的宏插件目录里缺少 SwiftUIMacros，
// 因此 SwiftUI 的 `@State` 宏无法展开（报错 "plugin for module 'SwiftUIMacros' not found"）。
// 实测同类的 @StateObject / @Binding / @Environment / @AppStorage / @FocusState 均可正常使用。
//
// 解决：提供 `@Stored`，语义与 `@State` 一致（含 `$xxx` 投影出 Binding），底层用 @StateObject 承载。
// 用法完全等价：
//     @Stored private var text = ""        →   text / $text 均可用
//     需要 Binding 入参时仍用 Binding<T> 或 @Binding（两者都实测可用）

public final class StoredBox<Value>: ObservableObject {
    @Published public var value: Value
    public init(_ value: Value) { self.value = value }
}

@propertyWrapper
public struct Stored<Value>: DynamicProperty {
    @StateObject private var box: StoredBox<Value>

    public init(wrappedValue: Value) {
        self._box = StateObject(wrappedValue: StoredBox(wrappedValue))
    }

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self.box.value }, set: { self.box.value = $0 })
    }
}
