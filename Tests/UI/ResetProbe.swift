//  ResetProbe.swift
//  「Reset chain のあとメーターが動かない」を機械で捕まえる。
//
//  報告（Level Meter を既定に置いていたころ）: リセットしたあとメーターが止まったままで、
//  カードの電源を切って入れ直すと直る。
//
//  いまは既定の鎖が空で、Level Meter のカードは出ない。代わりに出力補正の行の OUT メーター
//  （鎖の外に固定、SignalMeter.swift）がリセットの後も動き続けるかを見る。空の鎖でも
//  音は素通しで出ていくので、-ETMock 1 なら OUT は -96 dB より上にいるはず。
//  accessibility の写しは更新が遅れるので、待ってから読む。

import XCTest

final class ResetProbe: XCTestCase {

    /// リセット直後も OUT のメーターが値を出しているか。
    func testMeterAfterReset() {
        let app = XCUIApplication()
        app.launchArguments = ["-ETSeed", "VolumePlugin,CompressorPlugin",
                               "-ETWidth", "0", "-ETMock", "1"]
        app.launch()
        Thread.sleep(forTimeInterval: 8)

        var log: [String] = []

        // ⋯ → Reset chain → 確認
        let more = app.buttons["moreMenu"]
        XCTAssertTrue(more.waitForExistence(timeout: 15), "⋯ が出ない")
        more.tap()
        Thread.sleep(forTimeInterval: 2)

        let reset = app.buttons["Reset chain"]
        log.append("reset exists=\(reset.exists) enabled=\(reset.isEnabled)")
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "Reset chain が無い")
        reset.tap()
        Thread.sleep(forTimeInterval: 1.5)

        // 確認は .confirmationDialog。出てくるボタンの名前を控える。
        let names = (0..<app.buttons.count).compactMap { i -> String? in
            let b = app.buttons.element(boundBy: i)
            return b.exists ? b.label : nil
        }
        log.append("buttons after reset tap: \(names)")

        let confirm = app.sheets.buttons["Reset chain"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "確認に Reset chain が無い")
        confirm.tap()
        Thread.sleep(forTimeInterval: 6)

        // OUT のメーターが在るか。
        let meter = app.descendants(matching: .any)["outputMeter"].firstMatch
        log.append("outputMeter exists=\(meter.exists)")

        // メーターが値を出しているか。読み値は "dB" を含み、鳴っていれば下端（-96.0 dB）ではない。
        let texts = (0..<app.staticTexts.count).compactMap { i -> String? in
            let t = app.staticTexts.element(boundBy: i)
            return t.exists ? t.label : nil
        }
        log.append("texts: \(texts)")
        let moving = texts.contains { $0.contains("dB") && !$0.contains("-96.0 dB") }
        log.append("moving=\(moving)")

        print("PROBE-RESET\n" + log.joined(separator: "\n"))
        XCTAssertTrue(meter.exists, "リセット後に OUT のメーターが無い")
        XCTAssertTrue(moving, "リセット後にメーターが値を出していない")
    }
}
