// swift-tools-version: 6.0
import PackageDescription
import Foundation

// A machine-local checkout supplies the optional runtime. No private source URL
// or binary dependency is fetched by ordinary Memex builds.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let runtimeRoot = ProcessInfo.processInfo.environment["MEMEX_AGENT_RUNTIME_ROOT"]
    ?? (try? String(contentsOf: root.appendingPathComponent(".local-runtime-root"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
var dependencies: [Package.Dependency] = [.package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")]
var appDependencies: [Target.Dependency] = [.product(name: "Markdown", package: "swift-markdown")]
var linkerSettings: [LinkerSetting] = []
if let runtimeRoot, !runtimeRoot.isEmpty {
    dependencies.append(.package(path: runtimeRoot + "/packages/sq-acp"))
    dependencies.append(.package(path: runtimeRoot + "/packages/sq-ui"))
    appDependencies += [.product(name: "SQACP", package: "sq-acp"), .product(name: "SQACPHost", package: "sq-acp")]
    appDependencies.append(.product(name: "SQACPUI", package: "sq-ui"))
    let archive = ProcessInfo.processInfo.environment["MEMEX_AGENT_RUNTIME_LIBRARY"]
        ?? runtimeRoot + "/packages/sq-acp/target/runtime-native/aarch64-apple-darwin/release/libsq_acp_runtime.a"
    linkerSettings = [.unsafeFlags(["-Xlinker", archive]),
                      .linkedFramework("CoreFoundation"), .linkedFramework("CoreServices"), .linkedLibrary("iconv")]
}

let package = Package(
    name: "Memex",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Memex", targets: ["Memex"])],
    dependencies: dependencies,
    targets: [
        .executableTarget(name: "Memex", dependencies: appDependencies, linkerSettings: linkerSettings),
        .testTarget(name: "MemexTests", dependencies: ["Memex"]),
    ]
)
