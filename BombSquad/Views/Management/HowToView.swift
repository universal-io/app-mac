import SwiftUI

/// 使い方 — the shortcuts and gestures, in the window that has room for them.
///
/// This was a "?" in the compose bubble opening a popover. The bubble is the
/// narrowest surface in the product and everything in it competes with the one
/// thing it exists for, so reference text that is read once or twice does not
/// belong there. The management window is where a user goes to find out about
/// the app, and it can say more than a popover could.
///
/// The gesture key is read from the user's own keybinding rather than written
/// out, so a rebound key does not turn this page into instructions for a key
/// that does nothing.
struct HowToView: View {
    private var gestureKey: String { KeybindingSettings.gestureKey().hintLabel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("使い方").font(.title.weight(.semibold))
                    Text("キーひとつで呼び出し、そのまま書く・聞く・案内してもらう。")
                        .foregroundStyle(.secondary)
                }

                group(
                    "呼び出す",
                    note: "どのアプリを使っている時でも同じキーです。",
                    rows: [
                        ("\(gestureKey) ×2", "入力欄にいれば入力、文章を選んでいればその内容について、それ以外なら画面全体について"),
                        ("\(gestureKey) ×2（もう一度）", "入力から画面の解説へ進む / 閉じる"),
                        ("× / Esc", "閉じる（バブル右上の×か、Escキー）"),
                    ]
                )

                group(
                    "書く",
                    note: "送信ボタンはありません。Enterがそのまま送信です。",
                    rows: [
                        ("Enter", "書いたものを元の入力欄へ送る"),
                        ("Shift+Enter", "改行"),
                        ("\(gestureKey) ×1", "自分の下書きと、AIの文案・レビュー結果を行き来する"),
                        ("レビュー", "いま書いてある文を見てもらう"),
                        ("自動返信", "画面に写っている相手への返信文案をその場で作る"),
                    ]
                )

                group(
                    "話す",
                    note: "キーは押している間だけ、ボタンは押し直すまで録音します。",
                    rows: [
                        ("\(gestureKey) 長押し", "離すまで録音し、離すと文字になる"),
                        ("マイクのアイコン", "クリックで録音開始、もう一度クリックで停止"),
                    ]
                )

                group(
                    "画面について聞く",
                    note: "紫の幕が乗っている間、画面は操作するものではなく指すものになります。",
                    rows: [
                        ("入った瞬間", "質問しなくても、いまの画面の解説が始まる"),
                        ("クリック", "その場所について聞く"),
                        ("ドラッグで囲む", "囲んだ範囲について聞く"),
                        ("そのまま入力", "続けて質問できる"),
                    ]
                )

                group(
                    "案内してもらう",
                    note: "次の一手が答えになる質問をすると、幕が引いて案内に入ります。押すのはご自身です。",
                    rows: [
                        ("次に押す対象", "枠で示され、クリックは元のアプリへ通る"),
                        ("押したあと", "画面を撮り直して、目的に着くまで次の一手が出る"),
                        ("チップの ×", "解説（幕あり）へ戻る"),
                    ]
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("気をつけていただきたいこと").font(.headline)
                    Text("画面について聞く機能は、その時の画面を送信します。パスワード、シークレットキー、口座番号、本人確認書類などが写っている画面では使わないでください。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("使い方")
    }

    private func group(
        _ title: String,
        note: String,
        rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.0)
                                .font(.caption.monospaced())
                                .frame(width: 140, alignment: .leading)
                            Text(row.1)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }
}
