#include <metal_stdlib>
using namespace metal;

/// タイル処理のパラメータ。
/// Swift 側の GlowTileParams とレイアウトを一致させること（順序を変えたら両方直す）。
struct GlowTileParams {
    // 画像全体の座標系における、処理領域（マージン込み）の左上
    uint2 sourceOrigin;

    // 処理領域の寸法。タイル内座標はこの範囲
    uint2 regionSize;

    // 画像全体の寸法。読み出しクランプに使う
    uint2 imageSize;

    // 書き戻し先の左上（画像全体の座標系）
    uint2 outputOrigin;

    // 処理領域内での書き戻し元オフセット
    uint2 outputOffset;

    // 書き戻す寸法
    uint2 outputSize;

    // 畳み込み半径（タップ数は 2 * radius + 1）
    int radius;

    // 累積合成時の重み
    float weight;

    // グローに掛ける総合ゲイン
    float gain;

    // ノイズ下限
    float threshold;

    // PSF 成分ごとの明るさしきい値。畳み込み前に星成分から引く
    float componentThreshold;

    // 0 = Screen, 1 = Add
    uint blendMode;

    // 背景減算を行うなら 1
    uint hasBackground;
};

/// 処理領域の外にはみ出したスレッドを弾く。
static inline bool isOutsideRegion(uint2 gid, constant GlowTileParams &params) {
    return gid.x >= params.regionSize.x || gid.y >= params.regionSize.y;
}

/// 画像全体の座標へクランプする。
static inline uint2 clampToImage(int2 coord, constant GlowTileParams &params) {
    int maxX = int(params.imageSize.x) - 1;
    int maxY = int(params.imageSize.y) - 1;
    return uint2(
        uint(clamp(coord.x, 0, maxX)),
        uint(clamp(coord.y, 0, maxY))
    );
}

/// 処理領域内の座標へクランプする。
static inline uint2 clampToRegion(int2 coord, constant GlowTileParams &params) {
    int maxX = int(params.regionSize.x) - 1;
    int maxY = int(params.regionSize.y) - 1;
    return uint2(
        uint(clamp(coord.x, 0, maxX)),
        uint(clamp(coord.y, 0, maxY))
    );
}

/// 合成先バッファを元画像で初期化する。
kernel void initializeBase(
    texture2d<float, access::read> image [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant GlowTileParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (isOutsideRegion(gid, params)) {
        return;
    }

    uint2 source = clampToImage(int2(params.sourceOrigin + gid), params);
    float3 color = image.read(source).rgb;
    destination.write(float4(color, 1.0), gid);
}

/// 元画像を横方向にぼかす（背景推定の 1 パス目）。
kernel void blurHorizontalFromImage(
    texture2d<float, access::read> image [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant GlowTileParams &params [[buffer(0)]],
    constant float *weights [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (isOutsideRegion(gid, params)) {
        return;
    }

    int2 center = int2(params.sourceOrigin + gid);
    float3 sum = image.read(clampToImage(center, params)).rgb * weights[0];

    for (int k = 1; k <= params.radius; ++k) {
        float w = weights[k];
        sum += image.read(clampToImage(int2(center.x - k, center.y), params)).rgb * w;
        sum += image.read(clampToImage(int2(center.x + k, center.y), params)).rgb * w;
    }

    destination.write(float4(sum, 1.0), gid);
}

/// 星成分を横方向にぼかす（PSF 成分の 1 パス目）。
///
/// 読み込み時に成分ごとの明るさしきい値を引く。
/// 広い成分ほど高いしきい値なので、暗い星は芯だけ、明るい星は裾まで乗る。
/// これにより PSF の形自体が星の明るさで変わる。
kernel void blurHorizontal(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant GlowTileParams &params [[buffer(0)]],
    constant float *weights [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (isOutsideRegion(gid, params)) {
        return;
    }

    int2 center = int2(gid);
    float threshold = params.componentThreshold;
    float3 sum = max(source.read(gid).rgb - threshold, 0.0) * weights[0];

    for (int k = 1; k <= params.radius; ++k) {
        float w = weights[k];
        sum += max(source.read(clampToRegion(int2(center.x - k, center.y), params)).rgb - threshold, 0.0) * w;
        sum += max(source.read(clampToRegion(int2(center.x + k, center.y), params)).rgb - threshold, 0.0) * w;
    }

    destination.write(float4(sum, 1.0), gid);
}

/// タイル内バッファを縦方向にぼかす（結果で上書き）。
kernel void blurVertical(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant GlowTileParams &params [[buffer(0)]],
    constant float *weights [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (isOutsideRegion(gid, params)) {
        return;
    }

    int2 center = int2(gid);
    float3 sum = source.read(gid).rgb * weights[0];

    for (int k = 1; k <= params.radius; ++k) {
        float w = weights[k];
        sum += source.read(clampToRegion(int2(center.x, center.y - k), params)).rgb * w;
        sum += source.read(clampToRegion(int2(center.x, center.y + k), params)).rgb * w;
    }

    destination.write(float4(sum, 1.0), gid);
}

/// タイル内バッファを縦方向にぼかし、重み付きで累積結果へ足して別バッファへ書く。
/// 4 成分 PSF の各成分をここで積み上げる。
///
/// 読み込みと書き込みを別テクスチャに分ける（ping-pong）のは、
/// read_write テクスチャが Metal の read-write tier 2 を要求するため。
/// tier 1 の GPU でも動かせるようにしている。
kernel void blurVerticalAccumulate(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> accumulatorIn [[texture(1)]],
    texture2d<float, access::write> accumulatorOut [[texture(2)]],
    constant GlowTileParams &params [[buffer(0)]],
    constant float *weights [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (isOutsideRegion(gid, params)) {
        return;
    }

    int2 center = int2(gid);
    float3 sum = source.read(gid).rgb * weights[0];

    for (int k = 1; k <= params.radius; ++k) {
        float w = weights[k];
        sum += source.read(clampToRegion(int2(center.x, center.y - k), params)).rgb * w;
        sum += source.read(clampToRegion(int2(center.x, center.y + k), params)).rgb * w;
    }

    float3 accumulated = accumulatorIn.read(gid).rgb + sum * params.weight;
    accumulatorOut.write(float4(accumulated, 1.0), gid);
}

/// 累積バッファを 0 で埋める。
kernel void clearAccumulator(
    texture2d<float, access::write> destination [[texture(0)]],
    constant GlowTileParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (isOutsideRegion(gid, params)) {
        return;
    }

    destination.write(float4(0.0, 0.0, 0.0, 1.0), gid);
}

/// 星成分を取り出す。
///
/// 背景（大きくぼかした画像）を引くと、天の川のかぶりや空のグラデーションが消え、
/// 点像だけが残る。さらにノイズ下限を引いて高 ISO ノイズがにじむのを防ぐ。
kernel void extractStars(
    texture2d<float, access::read> image [[texture(0)]],
    texture2d<float, access::read> background [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant GlowTileParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (isOutsideRegion(gid, params)) {
        return;
    }

    uint2 source = clampToImage(int2(params.sourceOrigin + gid), params);
    float3 color = image.read(source).rgb;

    if (params.hasBackground != 0) {
        color -= background.read(gid).rgb;
    }

    float3 star = max(color - params.threshold, 0.0);
    destination.write(float4(star, 1.0), gid);
}

/// グローを合成先へ重ねる。
///
/// 不透明度はゲインへ畳み込んである（Screen も Add も
/// mix(base, blend(base, glow), opacity) == blend(base, glow * opacity) が成り立つ）。
kernel void compositeGlow(
    texture2d<float, access::read> base [[texture(0)]],
    texture2d<float, access::read> glow [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant GlowTileParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (isOutsideRegion(gid, params)) {
        return;
    }

    float3 baseColor = base.read(gid).rgb;
    float3 glowColor = max(glow.read(gid).rgb * params.gain, 0.0);

    float3 result;
    if (params.blendMode == 0) {
        // Screen: 1 - (1 - base) * (1 - glow)
        // glow が 1 を超えると式が破綻するため飽和させる
        result = 1.0 - (1.0 - baseColor) * (1.0 - saturate(glowColor));
    } else {
        result = baseColor + glowColor;
    }

    destination.write(float4(result, 1.0), gid);
}

/// タイルの中央部を、クリップせずに出力テクスチャへ書き戻す。
///
/// レイヤー別のグローは `rgba16Float` で保持し、強度や不透明度は描画時に掛ける。
/// ここで 1 に丸めてしまうと、あとから強度を上げたときに頭打ちになる。
kernel void writeTileOutputUnclamped(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant GlowTileParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) {
        return;
    }

    float3 color = max(source.read(params.outputOffset + gid).rgb, 0.0);
    destination.write(float4(color, 1.0), params.outputOrigin + gid);
}

/// レイヤー合成のパラメータ。Swift 側の CompositeParams と一致させる。
struct CompositeParams {
    uint2 imageSize;
    uint layerCount;
    // 1 なら原画を含めず、グロー成分だけを合成する
    uint glowOnly;
};

/// レイヤー 1 枚分の合成パラメータ。Swift 側の CompositeLayerParams と一致させる。
struct CompositeLayerParams {
    // 強度 x 不透明度
    float gain;
    // 0 = Screen, 1 = Add
    uint blendMode;
    uint isVisible;
    uint padding;
};

/// 保持してあるレイヤー別グローを原画へ合成する（書き出し用）。
///
/// 画素ごとに独立した計算なのでタイル分割は要らない。
/// 表示側の `canvasFragment` と同じ式にしてあるので、
/// プレビューと書き出しの見え方は一致する。
kernel void compositeLayers(
    texture2d<float, access::read> original [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    array<texture2d<float, access::read>, 8> glows [[texture(2)]],
    constant CompositeParams &params [[buffer(0)]],
    constant CompositeLayerParams *layers [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.imageSize.x || gid.y >= params.imageSize.y) {
        return;
    }

    float3 color = params.glowOnly != 0 ? float3(0.0) : original.read(gid).rgb;

    for (uint index = 0; index < params.layerCount; ++index) {
        if (layers[index].isVisible == 0) {
            continue;
        }

        float3 glow = max(glows[index].read(gid).rgb * layers[index].gain, 0.0);

        if (params.glowOnly != 0 || layers[index].blendMode != 0) {
            color += glow;
        } else {
            color = 1.0 - (1.0 - color) * (1.0 - saturate(glow));
        }
    }

    destination.write(float4(saturate(color), 1.0), gid);
}

/// タイルの中央部だけを出力テクスチャへ書き戻す。
/// マージン部分は隣のタイルが担当するので捨てる。
kernel void writeTileOutput(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant GlowTileParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.outputSize.x || gid.y >= params.outputSize.y) {
        return;
    }

    float3 color = source.read(params.outputOffset + gid).rgb;
    destination.write(float4(saturate(color), 1.0), params.outputOrigin + gid);
}
