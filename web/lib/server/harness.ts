// Tool harness selection for the screen navigator (docs/navigator-copilot-plan.md
// §9-a). The client never picks a harness: it only sends hints (frontmost app
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

/** One step of a task recipe. `target` is the exact on-screen label the
 * client resolves via OCR/AX; `fill` is approval-driven text entry. */
export type RecipeStep = {
  verbal: string;
  target?: string;
  fill?: string;
};

/** A known multi-step path through the tool's UI. Recipes are deterministic
 * data (docs/navigator-copilot-plan.md §3-b): the planner adopts a matching
 * recipe verbatim instead of inventing steps, and each recipe doubles as a
 * golden-set case. Placeholders like {ページパス} mark values the planner
 * must substitute from the user's actual question. */
export type Recipe = {
  goal: string;
  steps: RecipeStep[];
};

export type Harness = {
  id: string;
  promptBlock: string;
  recipes?: Recipe[];
};

export function selectHarness(hints?: NavigateHints): Harness | null {
  if (!hints) return null;
  const haystack = [hints.url, hints.window_title, hints.app_name]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  if (!haystack) return null;

  // Chrome's window title for GA4 is just the tab title — "アナリティクス"
  // without "Google" — and the client sends no URL hint yet, so the bare
  // title must match too (the 2026-07-06 harness miss: no recipes, no
  // planner, no GA4 knowledge, silently generic).
  if (
    haystack.includes("analytics.google.com") ||
    haystack.includes("google analytics") ||
    haystack.includes("google アナリティクス") ||
    haystack.includes("アナリティクス")
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
  - **トピックの対応（間違えやすい）**: 国・地域・言語・年齢・性別 → **ユーザー属性**。デバイス（mobile/desktop）・OS・ブラウザ・画面サイズ → **テクノロジー**。流入元・チャネル → **集客**。ページ別の閲覧 → **エンゲージメント**。
  - 「概要」という項目はユーザー属性・テクノロジー・各ライフサイクル配下など**複数箇所にある**。案内するときは必ず「どのセクションの下の概要か」を言葉で添え、位置マーカーで特定する。
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
  recipes: [
    {
      goal: "特定ページの指標（表示回数・セッション・ユーザー数など）を見る",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「エンゲージメント」を開く", target: "エンゲージメント" },
        { verbal: "「ページとスクリーン」を開く", target: "ページとスクリーン" },
        {
          verbal: "表の上の検索欄にページパスを入力して絞り込む",
          target: "検索",
          fill: "{ページパス}",
        },
        { verbal: "右上の期間セレクタで対象期間（先月・過去30日など）を選ぶ" },
        { verbal: "絞り込んだ行から対象の指標を読み取る" },
      ],
    },
    {
      goal: "直帰率を見る（既定レポートには無い指標）",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「エンゲージメント」を開く", target: "エンゲージメント" },
        { verbal: "「ページとスクリーン」を開く", target: "ページとスクリーン" },
        {
          verbal:
            "右上の鉛筆アイコン（レポートをカスタマイズ）を開く。見えない場合は編集者権限が無いので、探索で直帰率の表を組むか、目安として 100%−エンゲージメント率 を使う",
          target: "レポートをカスタマイズ",
        },
        { verbal: "「指標」を開いて「直帰率」を追加し、適用する", target: "指標" },
        { verbal: "表に追加された「直帰率」列を読み取る" },
      ],
    },
    {
      goal: "流入元（チャネル別のセッション数）を見る",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「集客」を開く", target: "集客" },
        { verbal: "「トラフィック獲得」を開く", target: "トラフィック獲得" },
        { verbal: "「セッションのデフォルトチャネルグループ」別の表から読み取る" },
      ],
    },
    {
      goal: "訪問者の国・地域・言語を見る",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「ユーザー属性」を開く", target: "ユーザー属性" },
        { verbal: "「ユーザー属性の詳細」を開く（国別の表が出る）", target: "ユーザー属性の詳細" },
        {
          verbal:
            "表のディメンション（列見出しのプルダウン）で「国」「地域」「市区町村」「言語」を切り替えて読み取る",
        },
      ],
    },
    {
      goal: "デバイス別（モバイル/デスクトップ）の利用状況を見る",
      steps: [
        { verbal: "左端のナビで「レポート」を開く", target: "レポート" },
        { verbal: "左メニューの「テクノロジー」を開く", target: "テクノロジー" },
        { verbal: "「ユーザーの環境の詳細」を開く", target: "ユーザーの環境の詳細" },
        {
          verbal:
            "表のディメンションを「デバイス カテゴリ」にして mobile / desktop / tablet の行を読み取る",
        },
      ],
    },
  ],
};
