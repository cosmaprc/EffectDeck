//  OutputCorrectionView.swift
//  出力補正（Output Correction）専用のシート。鎖の下の出力補正の行を押すと開く。
//
//  前は Presets のシートを丸ごと開き、その中の節で選ばせていた。そこではプリセットの行を押すと
//  鎖ごと読み込まれる（Presets の本来の動き）ので、補正を選ぶつもりで使う人の鎖を置き換えてしまった。
//  **ここには main の鎖へ何かを読み込む操作を置かない。**できるのは入切と、出力先ごとの紐付けだけ。
//  紐付けを選ぶ場所はここ 1 か所（Presets からは節を外した）。
//
//  **AudioIO は観測しない**（3.3Hz で publish する）。いまの出力先も紐付けも
//  OutputCorrection が publish しているものを読む。

import SwiftUI

struct OutputCorrectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var oc = OutputCorrection.shared
    @ObservedObject private var store = PresetStore.shared

    /// PC の鎖を編集している間（PipelineView が渡す）。補正は外してあるので、
    /// いまの出力先を「使っている」とは出さず、紐付けてあれば他の出力先と同じ並びに置く。
    let isRemote: Bool

    init(isRemote: Bool = false) {
        self.isRemote = isRemote
    }

    /// いま使っている出力先。まだ落ち着いた出力先が無い・リモート中は nil。
    private var current: ETOutputCorrectionDevice? { isRemote ? nil : oc.device }

    /// いまの出力先以外で、紐付けてある出力先。
    private var others: [ETOutputCorrectionBinding] {
        let key = current?.key
        return oc.bindings.filter { $0.key != key }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 鎖の下の行のトグルと同じもの。
                    Toggle("Output Correction", isOn: Binding(get: { oc.isOn }, set: { oc.setOn($0) }))
                }

                // 使う出力先が無いときは節ごと出さない（選んでも紐付ける先が無い）。
                if let d = current {
                    Section("In use") {
                        presetPicker(d)
                        // 紐付けたプリセットの中身（名前だけ・読むだけ）。鎖の下の行を開いたときと同じもの。
                        // oc.contents はいまの出力先の分だけなので、この節にだけ出す。
                        ForEach(oc.contents) { line in
                            Text(line.name)
                                .font(line.isSection ? Font.subheadline.weight(.semibold) : Font.subheadline)
                                .foregroundStyle(line.isSection ? .secondary : .primary)
                                .lineLimit(1)
                                .padding(.leading, line.indented ? 14 : 0)
                        }
                    }
                }

                if !others.isEmpty {
                    Section("Other devices") {
                        ForEach(others, id: \.key) { b in
                            let d = ETOutputCorrectionDevice(key: b.key, name: b.name, kind: b.kind)
                            presetPicker(d)
                                // 外すと紐付けが消え、行ごと無くなる（None を選んだのと同じ）。
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("Remove", role: .destructive) { oc.bind(d, preset: nil) }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Output Correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    /// 出力先 1 つの Picker。標準の Picker を押して別の画面で選ぶ。名前は保存してあるまま（フォルダ/名前）。
    /// 選ぶのは紐付けだけで、main の鎖には触らない。切のときも選べる（鳴らすのは入のときだけ）。
    private func presetPicker(_ d: ETOutputCorrectionDevice) -> some View {
        Picker(selection: Binding(get: { oc.preset(for: d.key) },
                                  set: { oc.bind(d, preset: $0) })) {
            Text("None").tag(String?.none)
            ForEach(store.names, id: \.self) { Text($0).tag(String?.some($0)) }
        } label: {
            Label(d.name, systemImage: ETOutputDevice.Kind(rawValue: d.kind)?.symbol ?? "speaker")
        }
        .pickerStyle(.navigationLink)
    }
}
