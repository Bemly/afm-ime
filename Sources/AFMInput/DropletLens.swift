import SwiftUI

/// 水滴折射 shader。构建期 package.sh 用 Xcode 工具链(xcrun metal -c + metallib)把
/// Metal/DropletLens.metal 编译成 default.metallib 放进 bundle,运行时 SwiftUI layerEffect 直接吃——
/// 无 deprecated API、无快照、全 GPU。
/// default.metallib 缺失(无 Xcode 的构建)时返回 nil → 水滴退化为纯玻璃无折射。
enum DropletLens {
    static var isAvailable: Bool {
        Bundle.main.url(forResource: "default", withExtension: "metallib") != nil
    }

    /// - Parameters:
    ///   - rect: 水滴矩形(幽灵行图层 user-space 坐标,点)
    ///   - refraction: (高度 pt, 折射量 pt;负值=向内拉,同 Kyant0 的 -refractionAmount)
    ///   - layerSize: 幽灵行图层尺寸(采样钳制用)
    static func maskShader(rect: CGRect, refraction: (h: CGFloat, amount: CGFloat), layerSize: CGSize) -> Shader? {
        guard isAvailable else { return nil }
        return ShaderLibrary.afmLensMask(
            .float4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
            .float2(Float(refraction.h), Float(refraction.amount)),
            .float2(Float(layerSize.width), Float(layerSize.height)))
    }

    static let maxSampleOffset = CGSize(width: 24, height: 24)
}
