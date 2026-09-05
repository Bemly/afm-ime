import CoreImage
import Foundation

/// 水滴折射渲染(Core Image 通用 kernel,运行时编译,无需 Metal 工具链——CLT 无 `metal` 编译器,
/// MTLLibrary 无序列化 API,CIKernel(functionName:from: Data) 拿不到运行时库,故走老 CIKL)。
/// 数学 1:1 移植 Kyant0/AndroidLiquidGlass 的 RoundedRectRefractionWithDispersionShader(AGSL):
/// 胶囊 SDF + circleMap(1-√(1-x²)) 边缘折射(SDF 梯度方向,amount 为负=向内拉→边缘放大镜) + 七采样色散。
/// 语法注记: 用老 CIKL(`sampler`/`sample()`/`samplerExtent`/`vec4`,CIKernel(source:) deprecated 但
/// 实测 macOS 27 仍可编译运行;现代 MSL CI kernel 需要 -fcikernel 编译标记,运行时编译器给不了)。
/// 探针实测(2026-09-06): 编译 ✓ 渲染 ✓ 水滴边缘把黑色块折射拉入 ✓。
enum DropletLens {
    private static let kernel: CIKernel? = {
        try? CIKernel(source: source)
    }()

    /// 共享 CIContext(GPU 后端);创建昂贵,全局一次
    private static let context = CIContext(options: [:])

    static var isAvailable: Bool { kernel != nil }

    /// 对幽灵行快照做水滴折射。
    /// - Parameters:
    ///   - ghost: 幽灵行快照(与正常行逐像素同布局,强调色样式)
    ///   - rect: 水滴矩形(**快照像素坐标**)
    ///   - refraction: (高度 px, 折射量 px;负值=向内拉,同 Kyant0 的 -refractionAmount)
    /// - Returns: 折射后的水滴区域图(与 rect 同尺寸,水滴外透明),失败 nil
    static func render(ghost: CGImage, rect: CGRect, refraction: (h: CGFloat, amount: CGFloat)) -> CGImage? {
        guard let kernel, rect.width > 2, rect.height > 2 else { return nil }
        let input = CIImage(cgImage: ghost)
        let args: [Any] = [
            input,
            CIVector(x: rect.minX, y: rect.minY, z: rect.width, w: rect.height),
            CIVector(x: refraction.h, y: refraction.amount),
        ]
        // 折射只向内采样(|amount| 进深),ROI 覆盖整个输入图(小图,开销可忽略)
        let out = kernel.apply(extent: rect.integral, roiCallback: { _, _ in input.extent },
                               arguments: args)
        return out.flatMap { context.createCGImage($0, from: rect.integral) }
    }
}

private let source = """
float sdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    float outside = length(max(cornerCoord, 0.0)) - radius;
    float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
    return outside + inside;
}

float2 gradSdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
        return sign(coord) * normalize(max(cornerCoord, 0.0));
    } else {
        float gradX = step(cornerCoord.y, cornerCoord.x);
        return sign(coord) * float2(gradX, 1.0 - gradX);
    }
}

float2 clampToImage(float2 p, sampler s) {
    float4 e = samplerExtent(s);
    return clamp(p, e.xy, e.xy + e.zw);
}

kernel vec4 afmLensed(sampler content, float4 rect, float2 refr) {
    float2 halfSize = rect.zw * 0.5;
    float2 centered = destCoord() - (rect.xy + halfSize);
    float radius = min(halfSize.x, halfSize.y);
    float sd = sdRoundedRect(centered, halfSize, radius);
    if (sd > 0.0) { return vec4(0.0); } // 水滴外 → 透明(AGSL 原版只作用于形状自身图层,无此外部分支)
    if (-sd >= refr.x || refr.x <= 0.0 || refr.y == 0.0) {
        return sample(content, clampToImage(destCoord(), content)); // 深处 → 原样
    }
    sd = min(sd, 0.0);
    float x = 1.0 - (-sd) / refr.x;
    float d = (1.0 - sqrt(1.0 - x * x)) * refr.y;
    float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
    float2 grad = gradSdRoundedRect(centered, halfSize, gradRadius);
    float2 base = destCoord() + d * grad;
    float2 disp = d * grad * ((centered.x * centered.y) / (halfSize.x * halfSize.y));
    // 七采样色散(AGSL 同款权重)
    vec4 color = vec4(0.0);
    vec4 red = sample(content, clampToImage(base + disp, content));
    color.r += red.r / 3.5;   color.a += red.a / 7.0;
    vec4 o2 = sample(content, clampToImage(base + disp * (2.0/3.0), content));
    color.r += o2.r / 3.5;    color.g += o2.g / 7.0; color.a += o2.a / 7.0;
    vec4 y2 = sample(content, clampToImage(base + disp * (1.0/3.0), content));
    color.r += y2.r / 3.5;    color.g += y2.g / 3.5; color.a += y2.a / 7.0;
    vec4 g2 = sample(content, clampToImage(base, content));
    color.g += g2.g / 3.5;    color.a += g2.a / 7.0;
    vec4 c2 = sample(content, clampToImage(base - disp * (1.0/3.0), content));
    color.g += c2.g / 3.5;    color.b += c2.b / 3.0; color.a += c2.a / 7.0;
    vec4 b2 = sample(content, clampToImage(base - disp * (2.0/3.0), content));
    color.b += b2.b / 3.0;    color.a += b2.a / 7.0;
    vec4 p2 = sample(content, clampToImage(base - disp, content));
    color.r += p2.r / 7.0;    color.b += p2.b / 3.0; color.a += p2.a / 7.0;
    return color;
}
"""
