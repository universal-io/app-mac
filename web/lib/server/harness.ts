// Tool harness selection for the screen navigator (docs/poc-ga-navigator.md
// §1-a). The client never picks a harness: it only sends hints (frontmost app
// name, window title, URL) and the gateway decides. No match → the generic
// navigator prompt alone, which must always work — the harness is an
// invisible accuracy add-on, not a mode.
//
// v0 harnesses are prompt packs written inline. Later they become updatable
// packages (docs RAG + UI map + task recipes) so a UI change ships as a data
// update, never a model change.

export type NavigateHints = {
  app_name?: string;
  window_title?: string;
  url?: string;
};

export type Harness = {
  id: string;
  promptBlock: string;
};

export function selectHarness(hints?: NavigateHints): Harness | null {
  if (!hints) return null;
  const haystack = [hints.url, hints.window_title, hints.app_name]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  if (!haystack) return null;

  if (
    haystack.includes("analytics.google.com") ||
    haystack.includes("google analytics") ||
    haystack.includes("google アナリティクス")
  ) {
    return GA4_HARNESS;
  }
  return null;
}

// --- GA4 (Google Analytics 4) pack v0 -------------------------------------
// UI map + task recipes for the demo scenario ("あるページの直帰率を見たい").
// Kept compact on purpose: the navigator must stay terse, the pack only has
// to prevent the classic wrong turns (bounce rate is absent from default
// reports; user acquisition vs traffic acquisition; editor-only customize).

const GA4_HARNESS: Harness = {
  id: "ga4",
  promptBlock: `# ツール知識: Google Analytics 4（GA4）
この画面は GA4 の可能性が高い。以下の UI マップとレシピを正として案内する。実際の画面と食い違う場合は画面を優先し、その旨を一言添える。

## UI マップ
- 画面左端の細いナビ（アイコン列）: ホーム / レポート / 探索 / 広告。
- 「レポート」内の左メニュー: レポートのスナップショット / リアルタイム / ユーザー（ユーザー属性・テクノロジー）/ ライフサイクル（集客・エンゲージメント・収益化・維持率）。
  - 集客 → ユーザー獲得: ユーザーの初回接点別。トラフィック獲得: セッション別。「流入経路」は通常トラフィック獲得。
  - エンゲージメント → ページとスクリーン: ページ別の指標表。表の上の検索欄でページパスを絞り込める。
- レポート表の右上: 検索 / 期間セレクタ / 共有 / 「レポートをカスタマイズ」（鉛筆アイコン。編集者以上の権限が必要）。
- 探索（Explore）: 自由形式の分析。左の「変数」列に指標・ディメンションを追加し、「タブの設定」へドラッグして表を組む。

## タスクレシピ
- 特定ページのトラフィックを見る: レポート → ライフサイクル → エンゲージメント → ページとスクリーン → 表の検索欄にページパス（例: /pricing）を入力。
- 直帰率を見る: **GA4 の既定レポートに直帰率は表示されない**。次のいずれか:
  1. ページとスクリーン → 右上の鉛筆（レポートをカスタマイズ）→ 指標 → 「直帰率」を追加 → 適用 → 保存。鉛筆が見えない場合は編集者権限が無いので 2 へ。
  2. 探索 → 空白 → 指標に「直帰率」、ディメンションに「ページパスとスクリーンクラス」を追加して表を組む。
  3. 目安だけなら: 直帰率 = 100% − エンゲージメント率。
- 流入元（チャネル別）を見る: レポート → ライフサイクル → 集客 → トラフィック獲得（セッションのデフォルトチャネルグループ）。`,
};
