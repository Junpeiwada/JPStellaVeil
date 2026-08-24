/*
 * sky_mask.jsx -- Photoshop の「空を選択」で空マスクを生成し、画像ファイルとして書き出す
 *
 * JPStellaVeil の自動空マスク（Phase 5）用。Photoshop 2021 以降の selectSky イベントを
 * ExtendScript から直接呼び出す。星景写真（天の川 + 明るい前景）でも実用精度で分離できる。
 *
 * 使い方（AppleScript 経由）:
 *   tell application "Adobe Photoshop 2026"
 *     do javascript (file POSIX file "…/sky_mask.jsx") with arguments {入力, 出力, 長辺px, 参照JPEG}
 *   end tell
 *   実際の呼び出しは sky_mask.sh を使うほうが簡単。
 *
 * 引数:
 *   [0] 入力画像パス（16bit TIFF 可）
 *   [1] 出力マスクパス。拡張子で形式が決まる:
 *         .tif/.tiff → 16bit グレースケール TIFF（LZW 圧縮）
 *         .png       →  8bit グレースケール PNG
 *   [2] 出力の長辺 px。省略または 0 でフル解像度。
 *   [3] 参照用 JPEG の出力パス（省略可）。マスクと同じ寸法の元画像を書き出す。目視確認用。
 *
 * 戻り値: JSON 文字列。{"ok":true,"width":…,"height":…} または {"ok":false,"error":"…"}
 *
 * 実装上の注意（いずれも実際に踏んだ罠）:
 *   - channels.add() すると編集対象チャンネルがアルファ側へ移る。RGB へ戻さずに塗ると、
 *     画像ではなくアルファチャンネルが塗られ、結果が元画像のまま出てくる。
 *   - アルファチャンネルを残したまま PNG 保存すると「透明度」として書き出され、
 *     カラー成分が全面白になる。焼き込み後に必ず remove する。
 *   - RGB のまま塗ってから changeMode(GRAYSCALE) すると、色変換で白が 255 に届かない
 *     （実測 247〜254）。グレースケール化を塗りつぶしより先に行う。
 *   - changeMode(GRAYSCALE) はアルファチャンネルを破棄する。ただし選択範囲は保持されるので、
 *     チャンネルへの退避はグレースケール化の後に行う。
 *   - 元ドキュメントに saveAs すると関連ファイルがそちらへ移り、開きっぱなし検出が効かなくなる。
 *     参照 JPEG は複製ドキュメントから書き出す。
 */

function escapeJSON(s) {
    return String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/[\r\n]/g, " ");
}

// 同じファイルが既に開いていれば閉じる。未保存の変更がある場合は中断する。
function closeIfAlreadyOpen(path) {
    var target = File(path).fsName;
    for (var i = app.documents.length - 1; i >= 0; i--) {
        var d = app.documents[i];
        var full;
        try { full = d.fullName.fsName; } catch (e) { continue; }  // 未保存の新規ドキュメント
        if (full !== target) continue;
        if (!d.saved) throw new Error("同じファイルが未保存の変更を抱えて開かれている: " + path);
        d.close(SaveOptions.DONOTSAVECHANGES);
    }
}

function generate(doc, outPath, longEdge, refPath) {
    var w = doc.width.as("px"), h = doc.height.as("px");
    var sixteenBit = (doc.bitsPerChannel === BitsPerChannelType.SIXTEEN);

    // 「空を選択」。前景・地平線の判定は Photoshop のモデルに任せる。
    // 精度を優先してフル解像度のまま実行する。
    executeAction(stringIDToTypeID("selectSky"), undefined, DialogModes.NO);

    doc.flatten();

    // 参照画像はカラーのうちに、複製ドキュメントから書き出す。
    // 元ドキュメントに saveAs すると関連ファイルがそちらへ移り、開きっぱなし検出が効かなくなる。
    if (refPath) {
        var refDoc = doc.duplicate();
        resizeToLongEdge(refDoc, longEdge);
        var jpg = new JPEGSaveOptions();
        jpg.quality = 8;
        refDoc.saveAs(File(refPath), jpg, true, Extension.LOWERCASE);
        refDoc.close(SaveOptions.DONOTSAVECHANGES);
        app.activeDocument = doc;
    }

    // 塗りつぶしより先にグレースケール化する。後にすると色変換で白が 255 に届かない。
    // changeMode はアルファチャンネルを破棄するが選択範囲は保持するので、退避はこの後に行う。
    if (doc.mode !== DocumentMode.GRAYSCALE) doc.changeMode(ChangeMode.GRAYSCALE);

    // 部分選択（ソフトエッジ）を階調のままアルファチャンネルへ退避する。
    var ch = doc.channels.add();
    ch.name = "SkyMask";
    doc.selection.store(ch);
    doc.selection.deselect();

    // 出力サイズの調整。アルファチャンネルも一緒に縮む。
    resizeToLongEdge(doc, longEdge);

    // channels.add() で移った編集対象を画像本体へ戻す。
    doc.activeChannels = doc.componentChannels;

    var black = new SolidColor(); black.rgb.hexValue = "000000";
    var white = new SolidColor(); white.rgb.hexValue = "FFFFFF";
    doc.selection.selectAll();
    doc.selection.fill(black);
    doc.selection.load(ch, SelectionType.REPLACE);
    doc.selection.fill(white);   // 部分選択はその割合で中間調になる
    doc.selection.deselect();

    // アルファチャンネルを残すと透明度として書き出されてしまう。
    ch.remove();

    if (outPath.toLowerCase().match(/\.tiff?$/)) {
        doc.bitsPerChannel = sixteenBit ? BitsPerChannelType.SIXTEEN : BitsPerChannelType.EIGHT;
        var tif = new TiffSaveOptions();
        tif.imageCompression = TIFFEncoding.TIFFLZW;
        tif.byteOrder = ByteOrder.IBM;
        tif.layers = false;
        tif.alphaChannels = false;
        doc.saveAs(File(outPath), tif, true, Extension.LOWERCASE);
    } else {
        doc.bitsPerChannel = BitsPerChannelType.EIGHT;
        doc.saveAs(File(outPath), new PNGSaveOptions(), true, Extension.LOWERCASE);
    }

    return '{"ok":true,"width":' + doc.width.as("px") + ',"height":' + doc.height.as("px") +
           ',"sourceWidth":' + w + ',"sourceHeight":' + h + '}';
}

function resizeToLongEdge(doc, longEdge) {
    if (longEdge <= 0) return;
    var w = doc.width.as("px"), h = doc.height.as("px");
    if (w <= longEdge && h <= longEdge) return;
    if (w >= h) doc.resizeImage(UnitValue(longEdge, "px"), null, 72, ResampleMethod.BICUBIC);
    else        doc.resizeImage(null, UnitValue(longEdge, "px"), 72, ResampleMethod.BICUBIC);
}

function run(inPath, outPath, longEdge, refPath) {
    closeIfAlreadyOpen(inPath);
    var doc = app.open(File(inPath));
    try {
        return generate(doc, outPath, longEdge, refPath);
    } finally {
        // 失敗しても必ず閉じる。残すと次回実行で加工済みドキュメントが再利用されてしまう。
        try { doc.close(SaveOptions.DONOTSAVECHANGES); } catch (e) {}
    }
}

var result;
var savedDialogs = app.displayDialogs;
var savedUnits = app.preferences.rulerUnits;
try {
    app.displayDialogs = DialogModes.NO;
    app.preferences.rulerUnits = Units.PIXELS;
    var longEdge = arguments.length > 2 && arguments[2] ? parseInt(arguments[2], 10) : 0;
    var refPath = arguments.length > 3 && arguments[3] ? arguments[3] : null;
    result = run(arguments[0], arguments[1], isNaN(longEdge) ? 0 : longEdge, refPath);
} catch (e) {
    result = '{"ok":false,"error":"' + escapeJSON(e.toString()) + '","line":' + (e.line || 0) + '}';
} finally {
    app.displayDialogs = savedDialogs;
    app.preferences.rulerUnits = savedUnits;
}
result;
