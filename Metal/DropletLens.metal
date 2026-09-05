// 候选条水滴折射(SwiftUI layerEffect,构建期由 package.sh 用 xcrun metal/metallib 编进 default.metallib)
// 数学 1:1 移植 Kyant0/AndroidLiquidGlass RoundedRectRefractionWithDispersion(AGSL):
// 胶囊 SDF + circleMap(1-√(1-x²)) 边缘折射(amount 负=向内拉→边缘放大镜) + 七采样色散;
// 水滴外输出透明。坐标: position 与 rect 同为该图层 user-space(点)。
#include <SwiftUI/SwiftUI_Metal.h>
#include <metal_stdlib>
using namespace metal;

static float sdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    float outside = length(max(cornerCoord, 0.0)) - radius;
    float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
    return outside + inside;
}

static float2 gradSdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
        return sign(coord) * normalize(max(cornerCoord, 0.0));
    } else {
        float gradX = step(cornerCoord.y, cornerCoord.x);
        return sign(coord) * float2(gradX, 1.0 - gradX);
    }
}

static float2 clampToLayerBase(float2 p, float2 layerSize) {
    return clamp(p, float2(0.0), layerSize);
}

[[stitchable]] half4 afmLensMask(float2 position, SwiftUI::Layer layer, float4 rect, float2 refr, float2 layerSize) {
    float2 halfSize = rect.zw * 0.5;
    float2 centered = position - (rect.xy + halfSize);
    float radius = min(halfSize.x, halfSize.y);
    float sd = sdRoundedRect(centered, halfSize, radius);
    if (sd > 0.0) { return half4(0.0); } // 水滴外 → 透明
    if (-sd >= refr.x || refr.x <= 0.0 || refr.y == 0.0) {
        return layer.sample(clampToLayerBase(position, layerSize)); // 深处 → 原样(含内容位移)
    }
    sd = min(sd, 0.0);
    float x = 1.0 - (-sd) / refr.x;
    float d = (1.0 - sqrt(1.0 - x * x)) * refr.y;
    float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
    float2 grad = gradSdRoundedRect(centered, halfSize, gradRadius);
    float2 base = position + d * grad;
    float2 disp = d * grad * ((centered.x * centered.y) / (halfSize.x * halfSize.y));
    // 七采样色散(AGSL 同款权重)
    half4 color = half4(0.0);
    half4 red = layer.sample(clampToLayerBase(base + disp, layerSize));
    color.r += red.r / 3.5;   color.a += red.a / 7.0;
    half4 o2 = layer.sample(clampToLayerBase(base + disp * (2.0/3.0), layerSize));
    color.r += o2.r / 3.5;    color.g += o2.g / 7.0; color.a += o2.a / 7.0;
    half4 y2 = layer.sample(clampToLayerBase(base + disp * (1.0/3.0), layerSize));
    color.r += y2.r / 3.5;    color.g += y2.g / 3.5; color.a += y2.a / 7.0;
    half4 g2 = layer.sample(clampToLayerBase(base, layerSize));
    color.g += g2.g / 3.5;    color.a += g2.a / 7.0;
    half4 c2 = layer.sample(clampToLayerBase(base - disp * (1.0/3.0), layerSize));
    color.g += c2.g / 3.5;    color.b += c2.b / 3.0; color.a += c2.a / 7.0;
    half4 b2 = layer.sample(clampToLayerBase(base - disp * (2.0/3.0), layerSize));
    color.b += b2.b / 3.0;    color.a += b2.a / 7.0;
    half4 p2 = layer.sample(clampToLayerBase(base - disp, layerSize));
    color.r += p2.r / 7.0;    color.b += p2.b / 3.0; color.a += p2.a / 7.0;
    return color;
}
