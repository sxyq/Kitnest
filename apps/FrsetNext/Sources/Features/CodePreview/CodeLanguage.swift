import Foundation

// MARK: - 代码语言目录（「所有代码」的落地：30+ 语言 + 自动识别）
//
// 语言 id 同时是高亮器的配置键；显示名走中文/通用名。
// 自动识别策略：文件扩展名（有的话）> 内容特征打分（取最高分）> 通用。

public struct CodeLanguage: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// 常见别名（从剪贴板/围栏里读到的 lang 标记）
    public let aliases: [String]
    /// 常见扩展名（无点）
    public let extensions: [String]

    public static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool { lhs.id == rhs.id }
}

public enum CodeLanguageCatalog {

    public static let auto = CodeLanguage(id: "auto", name: "自动识别", aliases: [], extensions: [])

    public static let all: [CodeLanguage] = [
        auto,
        CodeLanguage(id: "swift", name: "Swift", aliases: ["swiftui"], extensions: ["swift"]),
        CodeLanguage(id: "objc", name: "Objective-C", aliases: ["objective-c", "obj-c"], extensions: ["m", "mm", "h"]),
        CodeLanguage(id: "c", name: "C", aliases: ["h"], extensions: ["c", "h"]),
        CodeLanguage(id: "cpp", name: "C++", aliases: ["c++", "cc", "cxx"], extensions: ["cpp", "cc", "cxx", "hpp", "hh"]),
        CodeLanguage(id: "csharp", name: "C#", aliases: ["cs", "csharp", "dotnet"], extensions: ["cs"]),
        CodeLanguage(id: "java", name: "Java", aliases: [], extensions: ["java"]),
        CodeLanguage(id: "kotlin", name: "Kotlin", aliases: ["kt", "kts"], extensions: ["kt", "kts"]),
        CodeLanguage(id: "go", name: "Go", aliases: ["golang"], extensions: ["go"]),
        CodeLanguage(id: "rust", name: "Rust", aliases: ["rs"], extensions: ["rs"]),
        CodeLanguage(id: "python", name: "Python", aliases: ["py", "python3"], extensions: ["py", "pyw"]),
        CodeLanguage(id: "ruby", name: "Ruby", aliases: ["rb"], extensions: ["rb"]),
        CodeLanguage(id: "php", name: "PHP", aliases: [], extensions: ["php"]),
        CodeLanguage(id: "javascript", name: "JavaScript", aliases: ["js", "jsx", "node"], extensions: ["js", "jsx", "mjs", "cjs"]),
        CodeLanguage(id: "typescript", name: "TypeScript", aliases: ["ts", "tsx"], extensions: ["ts", "tsx"]),
        CodeLanguage(id: "dart", name: "Dart", aliases: ["flutter"], extensions: ["dart"]),
        CodeLanguage(id: "lua", name: "Lua", aliases: [], extensions: ["lua"]),
        CodeLanguage(id: "perl", name: "Perl", aliases: ["pl"], extensions: ["pl", "pm"]),
        CodeLanguage(id: "r", name: "R", aliases: ["rscript"], extensions: ["r"]),
        CodeLanguage(id: "matlab", name: "MATLAB", aliases: ["octave"], extensions: ["m"]),
        CodeLanguage(id: "sql", name: "SQL", aliases: ["mysql", "postgres", "postgresql", "sqlite"], extensions: ["sql"]),
        CodeLanguage(id: "shell", name: "Shell", aliases: ["sh", "bash", "zsh", "shellscript"], extensions: ["sh", "bash", "zsh", "command"]),
        CodeLanguage(id: "powershell", name: "PowerShell", aliases: ["ps1", "pwsh"], extensions: ["ps1", "psm1"]),
        CodeLanguage(id: "html", name: "HTML", aliases: ["htm", "vue"], extensions: ["html", "htm", "vue"]),
        CodeLanguage(id: "xml", name: "XML", aliases: ["plist", "svg"], extensions: ["xml", "plist", "svg", "storyboard", "xib"]),
        CodeLanguage(id: "css", name: "CSS", aliases: [], extensions: ["css"]),
        CodeLanguage(id: "scss", name: "SCSS", aliases: ["sass", "less"], extensions: ["scss", "sass", "less"]),
        CodeLanguage(id: "json", name: "JSON", aliases: ["jsonc", "json5"], extensions: ["json"]),
        CodeLanguage(id: "yaml", name: "YAML", aliases: ["yml"], extensions: ["yml", "yaml"]),
        CodeLanguage(id: "toml", name: "TOML", aliases: ["ini", "conf"], extensions: ["toml", "ini", "cfg"]),
        CodeLanguage(id: "markdown", name: "Markdown", aliases: ["md"], extensions: ["md", "markdown"]),
        CodeLanguage(id: "diff", name: "Diff", aliases: ["patch"], extensions: ["diff", "patch"]),
        CodeLanguage(id: "asm", name: "Assembly", aliases: ["nasm", "arm"], extensions: ["s", "asm"]),
        CodeLanguage(id: "plain", name: "纯文本", aliases: ["text", "txt", "plaintext"], extensions: ["txt", "text", "log"]),
    ]

    public static let byID: [String: CodeLanguage] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// 语言标记归一（"ts" → "typescript"，"sh" → "shell" …）；未知返回 nil
    public static func normalize(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if byID[key] != nil { return key }
        if let hit = all.first(where: { $0.aliases.contains(key) }) { return hit.id }
        // "c++11" / "python3.11" 这类带后缀的标记：取前缀再试一次
        for candidate in all where key.hasPrefix(candidate.id) { return candidate.id }
        for candidate in all where candidate.aliases.contains(where: { key.hasPrefix($0) }) { return candidate.id }
        return nil
    }

    public static func displayName(_ id: String) -> String {
        byID[id]?.name ?? id
    }

    public static func id(forExtension ext: String) -> String? {
        let key = ext.lowercased()
        // objc / c 都是 .h：优先 objc 只在内容含 @interface 时；这里按出现顺序返回首个
        return all.first(where: { $0.extensions.contains(key) })?.id
    }

    // MARK: - 自动识别

    /// 入口：优先用文件扩展名，其次内容特征打分。
    /// - Parameters:
    ///   - code: 源码文本
    ///   - fileName: 可选文件名（"a.swift"）
    public static func detect(_ code: String, fileName: String? = nil) -> String {
        if let fileName, let dot = fileName.lastIndex(of: ".") {
            let ext = String(fileName[fileName.index(after: dot)...])
            if let id = id(forExtension: ext) {
                // .h 头文件在 C / C++ / ObjC 间有歧义：交给内容判定
                if !["h", "m"].contains(ext.lowercased()) { return id }
            }
        }
        return detectFromContent(code)
    }

    /// 内容特征打分（分数相同取更靠前的规则；命中强特征直接返回）
    public static func detectFromContent(_ code: String) -> String {
        let sample = String(code.prefix(8000))
        let lower = sample.lowercased()

        // 强特征（唯一性很高，先判）
        if sample.contains("<?xml") { return "xml" }
        if sample.contains("<!DOCTYPE html") || sample.contains("<!doctype html") { return "html" }
        if lower.contains("#include") || lower.contains("std::") || lower.contains("using namespace") {
            return lower.contains("class ") && lower.contains("::") ? "cpp" : "cpp"
        }
        if sample.contains("import SwiftUI") || sample.contains("import Foundation") || sample.contains("@objc")
            || sample.contains("@State") || sample.contains("@Published") { return "swift" }
        if sample.contains("#import <") || sample.contains("@interface") || sample.contains("@implementation") { return "objc" }
        if lower.contains("package main") && lower.contains("func ") { return "go" }
        if lower.contains("fn ") && (lower.contains("let mut") || lower.contains("impl ") || lower.contains("use std")) { return "rust" }
        if lower.contains("fun ") && (lower.contains("val ") || lower.contains("var ")) { return "kotlin" }
        if lower.contains("using system") || sample.contains("namespace ") && lower.contains("public class") { return "csharp" }
        if sample.contains("public class") && lower.contains("system.out") { return "java" }
        if sample.contains("def ") && (sample.contains("self") || lower.contains("import ") || sample.contains("__init__")) { return "python" }
        if sample.contains("=> ") || sample.contains("console.log") || sample.contains("import react")
            || lower.contains("function ") || lower.contains("export default") {
            return sample.contains(": string") || sample.contains("interface ") ? "typescript" : "javascript"
        }
        if sample.contains("$") && (lower.contains("function ") || sample.contains("->")) && !lower.contains("<?php") { return "php" }
        if sample.contains("<?php") { return "php" }
        if lower.contains("select ") && lower.contains(" from ") { return "sql" }
        if sample.contains("#!/bin/") || sample.contains("#!/usr/bin/env") { return "shell" }
        if sample.contains("$(") && (lower.contains("param(") || lower.contains("function ")) { return "powershell" }
        if sample.contains("---\n") && sample.contains(": ") { return "yaml" }
        if sample.contains("@media") || sample.contains("{") && sample.contains(": ") && sample.contains(";")
            && !sample.contains("//") && (sample.contains("px") || sample.contains("#")) { return "css" }
        if sample.hasPrefix("{") || sample.hasPrefix("[") { return "json" }
        if sample.contains("<div") || sample.contains("<span") { return "html" }
        if sample.contains("def ") { return "python" }
        if sample.contains("func ") { return "swift" }
        if sample.contains("fn ") { return "rust" }
        if sample.contains("class ") && sample.contains("{") { return "java" }
        return "plain"
    }
}
