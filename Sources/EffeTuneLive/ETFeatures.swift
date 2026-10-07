//  ETFeatures.swift
//  建てるときに決まる機能の入切。**開け閉めはここの 1 行で済むようにする。**

enum ETFeatures {

    /// EffeTune Remote Control（DSP/RemoteMirror.swift・Views/RemoteScannerView.swift）。
    ///
    /// **店の版（Release）では入口を全部閉じる。**上流の EffeTune が LAN のリモート API をまだ出していないので、
    /// 店で入れた人にはつなぐ相手が居ない。Debug と Beta（ET_BETA。TestFlight）は開けたまま。
    /// 上流が出したら、ここを `true` にするだけで戻る。
    ///
    /// 閉じた版でもコードは建てる（入口から届かないだけ）。閉じるもの:
    ///   - 鎖の画面のツールバーのアイコン（RemoteToolbarButton。PipelineView）
    ///   - 設定画面の Remote の面（SettingsView.Pane）
    ///   - 撮影用の `-ETSheet remote`（PipelineView）
    ///   - 起動でのつなぎ直しと、つなぐこと全部（RemoteMirror.start・apply）。ベータで控えたつなぎ先が残っていてもつながない
    /// QR の読み取りは Remote のシートと面の中にしか無く、帯と中央の札はつながっているあいだしか出ない。
    /// http://host:port/?t=… や ws:// のリンクを外から開く口（onOpenURL）は持っていない。
    static var remoteControl: Bool {
        #if DEBUG || ET_BETA
        return true
        #else
        return false
        #endif
    }
}
