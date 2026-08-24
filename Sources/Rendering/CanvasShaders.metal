#include <metal_stdlib>
using namespace metal;

/// キャンバス表示用のパラメータ。
/// Swift 側の CanvasUniforms と レイアウトを一致させる。
struct CanvasUniforms {
    // 表示専用の露出倍率（書き出しには影響しない）
    float exposure;

    // マスクオーバーレイの不透明度。0 で非表示
    float maskOverlayOpacity;

    // スプリット比較の境界位置（0〜1）。1 で全面が処理結果
    float splitPosition;

    // 元画像比較が有効なら 1
    uint showOriginal;

    // マスクテクスチャが有効なら 1
    uint hasMask;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/// 画面全体を覆う三角形ストリップ。頂点バッファ不要。
vertex VertexOut canvasVertex(uint vertexID [[vertex_id]]) {
    // (-1,-1) (1,-1) (-1,1) (1,1) の順で 4 頂点
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    // テクスチャ座標は左上原点なので y を反転する
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

/// リニア値を sRGB へエンコードする。
/// 星空写真はリニアのままでは暗すぎて確認できないため、表示時のみ適用する。
static float linearToSRGBComponent(float value) {
    value = saturate(value);

    if (value <= 0.0031308) {
        return value * 12.92;
    }

    return 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

static float3 linearToSRGB(float3 color) {
    return float3(
        linearToSRGBComponent(color.r),
        linearToSRGBComponent(color.g),
        linearToSRGBComponent(color.b)
    );
}

fragment float4 canvasFragment(
    VertexOut in [[stage_in]],
    texture2d<float> processedTexture [[texture(0)]],
    texture2d<float> originalTexture [[texture(1)]],
    texture2d<float> maskTexture [[texture(2)]],
    constant CanvasUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler textureSampler(
        filter::linear,
        mip_filter::linear,
        address::clamp_to_edge
    );

    float3 processed = processedTexture.sample(textureSampler, in.texCoord).rgb;
    float3 original = originalTexture.sample(textureSampler, in.texCoord).rgb;

    // 元画像比較（押下中）は全面を原画に置き換える。
    // スプリット比較は境界より右側だけを処理結果にする。
    float3 color;
    if (uniforms.showOriginal != 0) {
        color = original;
    } else if (in.texCoord.x > uniforms.splitPosition) {
        color = processed;
    } else {
        color = original;
    }

    // 表示専用の露出調整（リニア空間で乗算）
    color *= uniforms.exposure;

    float3 displayColor = linearToSRGB(color);

    // マスクオーバーレイ: 適用領域を緑の半透明で示す
    if (uniforms.hasMask != 0 && uniforms.maskOverlayOpacity > 0.0) {
        float mask = maskTexture.sample(textureSampler, in.texCoord).r;
        float3 overlayColor = float3(0.0, 1.0, 0.35);
        displayColor = mix(displayColor, overlayColor, mask * uniforms.maskOverlayOpacity);
    }

    // スプリット比較の境界線を描く
    if (uniforms.showOriginal == 0 && uniforms.splitPosition > 0.0001 && uniforms.splitPosition < 0.9999) {
        float distanceToSplit = abs(in.texCoord.x - uniforms.splitPosition);
        float lineWidth = 0.0015;
        if (distanceToSplit < lineWidth) {
            displayColor = float3(1.0, 0.85, 0.2);
        }
    }

    return float4(displayColor, 1.0);
}
