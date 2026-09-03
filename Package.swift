// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "afm-ime",
    targets: [
        .target(name: "IMECore", path: "Sources/IMECore"),
        .executableTarget(name: "dictcompiler", dependencies: ["IMECore"], path: "Sources/DictCompiler"),
        .executableTarget(name: "dictbench", dependencies: ["IMECore"], path: "Sources/DictBench"),
        .executableTarget(name: "dbg", dependencies: ["IMECore"], path: "Sources/Debug"),
        .executableTarget(name: "afm-input", dependencies: ["IMECore"], path: "Sources/AFMInput"),
        .executableTarget(name: "afm-installer", dependencies: ["IMECore"], path: "Sources/AFMInstaller"),
    ]
)
