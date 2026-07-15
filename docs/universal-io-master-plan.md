# Universal I/O (I//O) マスタープラン

最終更新: 2026-07-14（vendor/product・tenant・user をVision専用ではなく全surface共通の
Context解決軸として定義。M4 の実装集中は維持）
ステータス: 承認済み（オーナー承認済みの製品方針。実装はマイルストーン M1 から開始）

このドキュメントは、Bomb Squad から **Universal I/O**（ロゴ: **I//O**）への製品転換の正本である。
別のエージェント／開発者がこのドキュメントだけを読んで実装を進められることを目的とする。
各マイルストーンの開始・完了・方針変更時には必ずこのファイルを更新すること。

関連ドキュメント:
- [README.md（ドキュメント索引）](README.md) — 全ドキュメントの一覧と役割。**まずここを見る**
- [foundation-rebuild-plan.md](foundation-rebuild-plan.md) — 現行の開発正本（基盤作り直し）
- [copilot-challenge-3.md](copilot-challenge-3.md) — **Navigator/Copilot（現在の中核機能）の正本**。
  2026-07-15 のワンコール・ピボット後の設計空間・判断・ロードマップ・UX仕様
- [api-contract.md](api-contract.md) — API 契約の正本
- [old/implementation-roadmap.md](old/implementation-roadmap.md) / [old/auth-billing-infra-plan.md](old/auth-billing-infra-plan.md) — アーカイブ（経緯資料）
- [../README.md](../README.md) — 現行実装（Bomb Squad 世代）の仕様

---

## 1. 製品ビジョン

### 1.1 コンセプト: 意味的 I/O レイヤー

Universal I/O は「インプットとアウトプットの間にあるもの」。
人間とアプリケーションの間には物理的な I/O レイヤー（キーボード・マイク・カメラ・スクリーン）が
既に存在する。I//O はその上に**意味・意図・認知の変換層**を新設する。

```
人間
 ↕ 物理層: キーボード / マイク / カメラ / スクリーン
 ↕ OS 層:  HID / ドライバ / イベント
 ↕ I//O:   意図・意味・認知の変換層   ← この製品
アプリケーション
```

- **Input 方向（人間→機械）**: 打鍵・音声を「意図」として受け取り、文脈と人格に沿った
  最適な文章へ変換して注入する。
- **Output 方向（機械→人間）**: スクリーン上の情報を、ユーザーの認知特性と目的に合わせて
  変換して提示する。

一言でいえば**「認知の眼鏡・補聴器」のデジタル拡張**。眼鏡が光を、補聴器が音を補正するように、
I//O は「意味」を双方向に補正する。当面の軸は **Vision（見る）** と **Voice（喋る）**。

### 1.2 北極星体験（North Star）

> **ホットキーを押してスクリーンを見せるだけで、「今何をすべきか」が分かり、
> そのアクション（メール返信なら文案まで）がエージェンティックに準備されていて、
> ユーザーはスクリーンをベースにただ承認していくだけですべてのタスクが終わっていく。**

- ユーザーの操作は「呼び出す」と「承認する」の 2 つに収束する。
- これは秘書型エージェントに接近するが、I//O の立場はあくまで
  **能力に大きなハンディキャップがある人のディスアビリティを限界まで埋めるレイヤー**である。
  自動実行はせず、最終判断（承認）は常に人間が行う。この原則は Bomb Squad 世代から不変。
- 全マイルストーンは、この北極星に向かう距離で優先度を判断する。

### 1.3 成立条件: ステートレスからの脱却

現行のレビューはステートレスで、レイヤーとして成立するには 2 軸が欠けている。

1. **Situational Context** — 入力中の文章の周辺文脈（どのアプリで、誰に、どんな会話の中で
   書いているか）。
2. **Personal Consistency** — ユーザーの人格的一貫性（文体・語彙・トーン・関係性ごとの距離感）。

瞬時に判断するのは不可能なので、**常に参照できるプロファイルを裏側でコツコツ積み上げる**
設計にする。ただし「使うほど良くなる」だけでは弱く、**初回でも成果が出る**ように
ブートストラップ（既存データの取り込み）を用意する。

### 1.4 ビジネス原則

- **最高のモデルでリッチな体験を優先する**。コストが高くても構わない。体験そのものが
  マーケティングである。
- したがって**ユーザー課金（サブスクリプション）が製品の中核**。BYOK（ユーザーが API キーを
  持ち込む方式）は開発者向けフォールバックに格下げする。
- モデル選択 UI はユーザーから隠す方向（プランと自動ルーティングが品質を決める）。

### 1.5 マルチデバイス前提

macOS の後、iOS（カスタムキーボード。`app-ios/BombSquadKeyboard` に着手済み）、
Android、Windows へ展開する。**ペルソナ・メモリ・課金はデバイス間で共有**されなければ
ならないため、知能とステートはサーバー側（Gateway）に集約する（M3）。

---

## 2. 用語定義

| 用語 | 意味 |
|---|---|
| **I//O パネル** | 右Shift 2回で呼び出す一時パネル（現 `ReviewPanelView` 系）。限界まで切り詰める |
| **管理ウィンドウ / マイページ** | メニューバーから開く通常ウィンドウ（現 `ManagementView`）。メモリ・履歴・プラン・設定 |
| **L1 / Situational Context** | 起動瞬間の周辺文脈（前面アプリ、会話スレッド、画面内容） |
| **L2 / Relationship Card** | 相手ごとのカード（呼称・敬語レベル・関係性・やり取り要約） |
| **L3 / Persona Card** | ユーザー自身のスタイルプロファイル（語彙・文体・NG 表現・価値観） |
| **Context Engine** | L1〜L3 を収集・蒸留・注入する仕組みの総称 |
| **App Vendor / Product** | 業務アプリの提供元と製品。例: Google / GA4、Salesforce / Sales Cloud。OpenAI等の `Model Provider` とは別概念 |
| **Tenant** | 認証・データ分離・課金・組織設定の境界。個人利用でも personal tenant を持ち、企業導入時は組織tenantになる |
| **User Context** | tenantに所属する個人の言語・認知特性・説明粒度・Persona等。組織ポリシーを上書きしない |
| **Surface** | Contextを利用する製品機能。現在は Compose / Transform / Vision（Navigator/Copilotを含む） |
| **Resolved Context** | 認証済みtenant/userと現在状況からGatewayが解決し、surfaceに必要な部分だけ投影した版付きContext |
| **Gateway** | サーバー側 API（FastAPI）。モデルルーティング・メモリ・課金メータリングを担う |
| **Deploy** | 変換結果を呼び出し元フィールドへ注入する操作（Bomb Squad 世代からの用語） |

---

## 3. アーキテクチャ全体像

### 3.1 共有Context Engine: 2軸＋surface projection

`L1 Situational / L2 Relationship / L3 Persona` と、Navigator v4で導入する
`generic / app vendor-product / tenant / user` は競合する分類ではない。前者は**内容と寿命**、
後者は**適用範囲と権限主体**を表す直交した軸である。

#### 軸A: 内容と寿命（既存L1〜L3）

| 層 | 寿命 | 収集タイミング | 保存先 | 注入方法 |
|---|---|---|---|---|
| L1 Situational | パネル1セッション | パネル召喚の瞬間に自動 | メモリ上のみ（保存しない） | プロンプトの context ブロック |
| L2 Relationship | 永続 | 送信後にバックグラウンド蒸留 | ローカル SQLite → M3 で Supabase | L1 から相手を特定してカードを注入 |
| L3 Persona | 永続 | オンボーディング＋送信ごとの増分＋定期蒸留 | 同上 | 常にシステムプロンプトへ注入 |

#### 軸B: 適用範囲と権限主体

| scope | 主体・キー | 共通用途 | Composeへの例 | Visionへの例 |
|---|---|---|---|---|
| generic | 全利用者 | I//Oの安全原則、基本能力 | 一般的な文章支援 | 未知画面の理解・案内 |
| app vendor / product | `app_vendor_id` + `product_id` | 製品用語、標準UI、標準的な使い方 | Slackのchannel/thread/DMの意味、投稿欄の目的 | Slack/Notion/GA4のUI map、代表task、完了条件 |
| tenant | 認証済み `tenant_id` | 個社用語、権限、業務規則、カスタムUI、参照知識 | 社名・承認フロー・禁止表現・Salesforce項目 | 個社ERP、カスタムSalesforce、許可された操作経路 |
| user | JWTの `user_id` | 言語、認知特性、説明粒度、Persona、個人設定 | 文体、語彙、相手との距離感 | やさしい説明、1step粒度、読み上げ方 |
| situation | session/capture/input ID | 今この瞬間に関係する対象を選ぶ | 前面app、入力欄、周辺会話、宛先 | 最新画面、window/URL、OCR/AX、Task進捗 |

`App Vendor` と実際のpack適用単位である `Product/Tool` は分ける。Google全体を1packにせず、
GA4とGmailは別productとして版管理する。`vendor` はOpenAI/Groq等のAIモデル提供者を指さない。
コード・DB・計測では `app_vendor` と `model_provider` を明記して衝突を避ける。

Tenantは「企業向け機能」の別名ではなく、常にデータ隔離と設定解決の境界である。現行は
全ユーザーにpersonal tenantを作る。将来userが複数組織へ所属する場合も、リクエストごとに
active tenantを1つ確定し、そのtenant以外のContextを絶対に混ぜない。個人の好みをtenant設定へ、
会社の知識をuser設定へ保存しない。

#### Contextの関心領域（prompt文字列ではなく型付きmodule）

| module | 内容 | 主なscope | 主なsurface |
|---|---|---|---|
| identity | user / active tenant / membership | tenant・user | 全surface |
| environment | app vendor、product、version、window/URL | product・situation | 全surface |
| terminology | 標準語・社内語・alias・表示名 | product・tenant | Compose / Vision |
| knowledge | 手順書、業務知識、検索参照 | product・tenant | Compose / Vision |
| policy | データ取扱い、禁止事項、確認必須action | generic・tenant | 全surface |
| presentation | 言語、認知支援、説明粒度、Persona | user | 全surface |
| relationship | 相手、呼称、関係、会話履歴の蒸留 | user・situation | 主にCompose/Transform、必要時Vision |
| capabilities | task recipe、pre/postcondition、target意味、field intent | product・tenant | surface別module |

packをそのままsystem promptへ連結する方式を完成形にしない。Gatewayの共通Context Resolverが
認証済みidentityとsituationから必要なpack/card/knowledgeを選び、出所とversionを保持した
`ResolvedContext` を作る。各surfaceはそこから必要最小限のmoduleだけを受け取る。

```text
authenticated user + active tenant + current situation
                         ↓
               Shared Context Resolver
  generic → product → tenant → user（出所・version付き）
                         ↓
       Compose projection  /  Vision projection
```

- Compose projection: field intent、channel慣習、周辺会話、tenant用語・policy、Persona/Relationship。
  Navigator recipeや画面座標は入れない。
- Vision projection: Observation、UI semantics、task recipe、grounding/verifier条件、tenant用語・policy、
  userの説明方法。署名や送信文体など無関係なMemoryは入れない。
- 同じSlack/product、tenant用語、userの言語・認知設定、policyは共通の正本から解決する。
  surfaceごとのコピーを作らない。

#### 合成規則（単純なlast-write-winsは禁止）

1. genericとtenantの安全・データpolicyは**より厳しい方**を採用し、user/situationは緩和できない。
2. productは標準の意味と能力を提供し、tenantは認証された範囲で名称・経路・カスタム項目を追加／置換できる。
3. userはpresentationと個人Memoryを調整できるが、事実・組織手順・許可actionを変更できない。
4. situationは永続設定を上書きするデータ源ではなく、「今どの一部を使うか」を選択する。
5. 解決結果には各moduleのscope、source ID、versionを残し、なぜその案内／文章になったか追跡可能にする。
6. L1の画面・会話本文は従来どおりsession内のみ。ResolvedContextの監査では本文でなく、
   適用したsource/versionとboolean/件数を既定で記録する。

#### 現状と移行先

| 領域 | 現在 | あるべき状態 |
|---|---|---|
| L1 | Compose/Transform/Visionで同じローカル `SituationalContext` | 共通Observation/Situation契約。surface別に必要情報を採取 |
| L2/L3 | ローカルMemoryを各Sessionが個別に検索・注入 | user Context moduleとして共通Resolverから版付き選択 |
| product | Navigatorのglobal harnessのみ。Composeにはapp固有Contextなし | 1つのproduct正本からCompose/Vision別capabilityを投影 |
| tenant | auth・課金・usageの境界。Navigator DB列は実行時未使用 | 全surface共通の隔離・policy・knowledge overlay境界 |
| user | JWT identityとローカルPersona/Relationshipが分離 | tenant所属を保ちつつ個人設定・Memoryを共通解決 |
| trace | surfaceごとに断片的 | resolved source/versionとsurface projectionを共通形式で計測 |

#### 現在の実装境界（2026-07-14）

この全体設計は今決めるが、実装はNavigator/Copilotの精度改善に集中する。まずVision側で
Observation、candidate ID、structured Verifier、版付きproduct packを作る。ただし名称・ID・
provenance・policy合成は共通Context Resolverへ昇格できる形にし、`vision_*` 専用のtenant/user
階層を新設しない。Compose/TransformへのResolver接続、DBの汎用pack schema、設定UIは
Visionの縦切りが評価で成立した後に行う。

#### Navigator Runの全体システム上の位置（2026-07-14）

RunはVision専用の会話履歴ではなく、ユーザーが承認しながら複数stepを完了するための短命な
実行状態である。将来Compose側に複数step taskが生じても同じidentity/context規則を使う。

- Gatewayがrunの論理ownerかつ唯一のwriter。JWTから確定したtenant/user scopeのSupabase rowで
  `current_step/status/revision` を管理し、clientはtyped snapshotのcache/echoだけを行う。
- 永続rowはrun/identity、pack+planのID・version・hash、step/status/revision、時刻だけに絞る。
  Task本文はGateway署名付きsnapshotで輸送し、画像/OCR/AX candidate/会話/モデル自由文は保存しない。
- `generic → product → tenant → user` のResolved Contextはrun開始時のsource/versionを固定し、
  run中に別tenantや無関係な最新packへ暗黙切替しない。再計画はrevisionを上げた明示イベントにする。
- active/terminal runはいずれも最終操作から24時間以内に失効・purgeする。長期の品質分析は本文を
  持たないaggregate traceと、明示同意・redaction済みeval fixtureへ分離する。
- Copilotのstep advanceは、クリック後の新規captureという独立証拠に基づく次ターンの判断で
  確定する（2026-07-15 ピボット。独立Verifierロールと信頼度ゲートは廃止、stale capture等の
  データ整合性検査は維持。正: [copilot-challenge-3.md](copilot-challenge-3.md) §5）。
  自由文回答やclient markerを状態の根拠にしない原則は不変。typed postcondition（レシピ）は
  後から載せる精度レイヤー。

実装原則:
- **fine-tuning はしない**。構造化カード（Markdown）のプロンプト注入＋類似実例の few-shot 検索
  （M3 以降 pgvector）で実現する。モデル世代交代に追従でき、ユーザーがカードを直接編集できる。
- **教師データの本命は「レビュー結果をユーザーがどう編集して送信したかの差分」**。
  `LocalHistoryStore` には既に `source_text` / `final_text` があり、この資産をそのまま使う。
- メモリは**マイページで全件閲覧・編集・削除できる**こと。透明性が信頼と継続動機を生む。

### 3.2 Thin Client / Fat Gateway（M3 で移行）

```
[macOS: NSPanel + AX 注入]  [iOS: カスタムキーボード + 共有シート]  [Windows: 後発]
         └──────────────────────┬──────────────────────┘
                    I//O Gateway（FastAPI）
      ・モデルルーティング（タスク × プラン × レイテンシ）
      ・Context Engine（カード生成 / pgvector 検索 / 蒸留）
      ・課金メータリング / レート制御（Stripe）
      ・プロンプト管理（アプリリリース不要で改善）
         └── Supabase: Auth（既存）/ Postgres + pgvector / Realtime 同期
    クライアント側: SQLite キャッシュ + オフラインフォールバック
```

- クライアントは「キャプチャ（画面・音声・選択テキスト）と注入（⌘V 合成 → 将来 AX 直接注入）」
  だけを担うセンサー＆アクチュエータに徹する。
- LLM プロバイダの API キーはクライアントに置かない（現 Keychain BYOK は開発者モードに格下げ）。
- M1〜M2 の段階では既存のクライアント直叩き（`ReviewProvider`）のまま進めてよい。
  抽象化（`ReviewProvider` / `VisionProvider` / `Deployer` プロトコル）が既にあるので、
  M3 で `GatewayReviewProvider` を差し込むだけで移行できる構造を維持すること。

### 3.3 モデル戦略

- 既定は最高品質（Claude Opus / Sonnet 系）＋**ストリーミング必須**。
  最初のトークンが数百 ms で出れば、リッチモデルの遅さは体感から消える。
- 速度が命の箇所（ASR、L1 抽出、先行プレビュー）のみ高速モデル（Groq 系）。
  「大きいモデルで理解 → 速いモデルで整形」の知見（README 参照）は
  「速いモデルで先行プレビュー → リッチモデルの本結果で差し替え」として活かす。
- 課金プラン: Standard ¥1,980/月 / Pro ¥4,980/月（2026-07-03 オーナー決定）＋
  フェアユース上限。原価は 1 変換あたり数円〜十数円で吸収可能。
  **更新（2026-07-08 オーナー決定）**: プラン→クォータ/機能の定義は DB の `bs_plans`
  テーブルが唯一の正本（migration 0004。env・プロビジョニングコードにコピーを持たない）。
  ベータ期間中は**機能ゲート無しの全開放**、free のみ 500 件/月、他プランは当面無制限。
- **可用性の原則（2026-07-03 オーナー決定）**: 事業者側の都合（プロバイダ障害・
  プロバイダ側レート制限・事業者クォータ設定ミス）でユーザーが機能を使えない状態を
  作らない。Gateway の各機能（ASR・レビュー・Vision）はプロバイダ障害時に**自動で
  第二エンジンへフォールバック**する。ユーザー自身のプランクォータによる停止は正当。
  **2026-07-14追記**: fallback/retryで可用性を保ってもerrorを隠さない。失敗元と実際に使った
  engineを共通警告としてユーザーへ表示し、運用traceにはnotice codeを残す。
  事業者側のコスト上限（青天井破産の防止）は必要であり、リリース時に慎重に設定する。
  最初の適用対象は ASR（Groq whisper がクォータ/障害でダウンする事象を確認済み）。

### 3.4 プライバシー原則（機能ではなく約束）

画面と私信を扱う製品なので、以下をマーケティングレベルの約束として全マイルストーンで守る:

1. **送信前に何が送られるか見える**（L1 コンテクストはパネル上でチップ表示、クリックで内容確認・除外可能）
2. **メモリは全件編集・削除可能**（マイページ）
3. **学習利用なし**（LLM プロバイダの no-training 設定 / DPA を利用）
4. L1 は保存しない。永続化するのは蒸留後のカードと履歴のみ（履歴は既存どおり設定で OFF 可）
5. 画面から得たcandidate label/rect、OCR、スクリーンショット、会話本文はproduction traceへ
   保存しない。run rowもID/version/revision等の最小状態に限り24時間以内にpurgeする

### 3.5 UI デザイン原則

- **徹底的に OS ネイティブ**。macOS 26 (Tahoe) の Liquid Glass を採用
  （SwiftUI `glassEffect` / NSGlassEffectView。macOS 14 デプロイターゲットを引き上げる場合は
  可用性チェックとフォールバック=現行 material を用意）。
- SF Symbols・システムカラー・vibrancy・標準コントロールのみ。独自デザインは
  I//O ロゴグリフと diff 配色だけに絞る。
- I//O パネルは Spotlight / Raycast 型: 1 入力欄＋結果。状態は 3 つだけ
  （空 → 原文あり → 結果あり）。**モデル選択・言語選択プルダウンはパネルから撤去**し、
  管理ウィンドウへ移す。
- コア UI は **diff 表示**（`DiffView` を昇格）。「何を・なぜ変えたか」が 1 秒で読めること。
- メニューバーアイコンはテンプレート画像のモノクロ「I//O」グリフ。
- VoiceOver・フルキーボード操作・コントラストを最初から満たす。
  認知アクセシビリティの製品が UI アクセシビリティを欠くのは思想矛盾。
- アニメーションはシステムのスプリングとクロスフェードのみ。

---

## 4. 現状コードベースの地図（実装者向け）

> 本表は 2026-07-13 の新中枢切替後を反映。Navigator/Copilot のUX詳細は
> [copilot-challenge-3.md](copilot-challenge-3.md) §7.1、基盤作り直しの経緯は
> [foundation-rebuild-plan.md](foundation-rebuild-plan.md) を参照。

リポジトリ: `git@github.com:universal-io/app-mac.git`（ローカル: `~/projects/universal-io/app-mac`。
2026-07-02 に GitHub org を `hey-watchme/mac-bomb-squad` から `universal-io/app-mac` へ移行し、
同日ローカルの親フォルダも `bomb-squad` から `universal-io` へ改名済み）
ビルド: `xcodegen generate` → `xcodebuild -project BombSquad.xcodeproj -scheme BombSquad -configuration Debug build`
コード内コメント・識別子は英語（CLAUDE.md 規約）。リネームは M5 まで行わず `BombSquad` 名前空間のまま実装する。

| 責務 | 場所 |
|---|---|
| アプリ起動・グローバル入力配線 | `BombSquad/AppDelegate.swift` |
| 右Shift 1回/2回/長押し判定 | `BombSquad/Services/ShiftGestureMonitor.swift` |
| 状態機械・セッション遷移 | `BombSquad/Core/AppMode.swift`, `SessionCoordinator.swift` |
| モード別状態・実行 | `BombSquad/Core/ComposeSession.swift`, `TransformSession.swift`, `VisionSession.swift` |
| プロンプ正本 | `BombSquad/Resources/ReviewPrompt.swift`（送信レビュー）、`web/lib/server/*-engine.ts`（Gateway経路） |
| LLM クライアント抽象 | `BombSquad/Services/ReviewProvider.swift`, `OpenAICompatibleClient.swift`, `ClaudeClient.swift`, `VisionProvider.swift`, `OpenAIVisionClient.swift` |
| モデルカタログ | `BombSquad/Models/AIProvider.swift`（`ReviewModel.catalog`） |
| 注入・クリップボード | `BombSquad/Services/PasteDeployer.swift`, `Deployer.swift`（`ClipboardBackup`, `ClipboardDeployer`）, `SelectionGrabber.swift` |
| スクリーンショット | `BombSquad/Views/ScreenshotSelectionOverlay.swift`, `Services/ScreenshotCaptureService.swift`（ScreenCaptureKit優先） |
| 音声 | `BombSquad/Services/AudioRecorder.swift`, `GroqTranscriber.swift` |
| ローカル履歴 | `BombSquad/Services/LocalHistoryStore.swift`（SQLite `history_entries`: `source_text`, `final_text`, `mode`, `action` 等） |
| パネル UI | `BombSquad/Core/*SessionView.swift`, `Core/PanelController.swift`, `Views/FoundationSharedViews.swift` |
| 管理ウィンドウ | `BombSquad/Views/Management/`（`ManagementView`, `AccountView`, `GeneralSettingsView`, `PricingView`, `HistoryPlaceholderView`） |
| 認証（Supabase） | `BombSquad/Services/BombSquadAuthClient.swift`, `ViewModels/AuthViewModel.swift` |
| 権限 | `BombSquad/Services/AccessibilityPermission.swift`, `ScreenCapturePermission.swift` |

---

## 4.5 配布パイプライン（2026-07-04 完成・実機確認済み）

App Store を通さず、公証済み DMG を Web から直接配布する経路が完成した。
「製品サイトのボタン → ダウンロード → 起動 → ログイン → 使える」を実機で確認済み
（フィードバック獲得フェーズの土台）。詳細手順は [../README.md](../README.md) の「配布（ベータ）」。

- **署名分岐**（[`project.yml`](../project.yml) の `configs`）: Debug=`Apple Development`
  ＋チーム `TG68TFXG88`（安定した証明書署名。ad-hoc はビルドごとに TCC 許可が無効化されるため禁止）、
  Release=Developer ID Application（有料チーム `TG68TFXG88`）+ Hardened Runtime + マイク entitlement
  （[`BombSquad/BombSquad.entitlements`](../BombSquad/BombSquad.entitlements)）。
  Apple の2チームの使い分けは `~/AGENTS.md` の「Apple Developer Accounts」に記録。
- **1コマンドリリース**: [`tools/release.sh`](../tools/release.sh) が
  build → sign → notarize → staple → DMG → R2 アップロードを実行。`SKIP_NOTARIZE=1` で
  署名検証のみ。公証資格は keychain profile `universal-io-notary`（app用パスワード方式）。
- **ホスティング**: Cloudflare R2 バケット `universal-io-downloads` → カスタムドメイン
  `dl.universal-io.com`。DMG はバージョン付き + 固定名 `Universal-IO.dmg`（latest）。
  R2 認証は aws CLI プロファイル `r2`、設定は gitignore された `tools/release.env`。
- **ダウンロード導線**: 製品サイト（`web-product`）のヒーロー主ボタンを
  `https://dl.universal-io.com/Universal-IO.dmg` に変更（waitlist メール登録は下部に維持）。
- **現行バージョン**: 0.1.0（公証済み DMG を配布中）。
- **残・次の一手**:
  - app用パスワードのローテーション（チャットに露出したため任意だが推奨）。
  - Stripe 課金（M3 残）。ベータ配布中は招待者に Pro 相当を付与すれば課金なしで使ってもらえる。
  - 製品サイトと Gateway（`web/`）の認証 UI のトンマナ統一（`web-product` の
    デザイントークン／コンポーネント指定に合わせる。UX 上のログイン導線が確定する前でも、
    ログインページ単体のスタイルを先に揃える方針）。

## 5. マイルストーン

進め方の原則:
- 1 マイルストーン = 1 ブランチ（`feature/universal-io-m1` のように切る。ベースは `feature/universal-io`）。
- 各マイルストーンの完了条件は「受け入れ基準」をすべて満たし、ビルドが通り、実機で動作確認済みであること。
- スコープ外のリファクタリング・機能追加はしない（CLAUDE.md「過剰設計の回避」）。

### M1: Situational Context 注入（L1）

ステータス: 完了（`feature/universal-io-m1`、2026-07-02 実機確認済み）。

実装済み: AX 収集（フォーカス要素起点の拡張探索＋Electron 向け AXManualAccessibility リトライ）、
チップ UI（内容確認・セッション除外）、設定トグル、全プロバイダへのプロンプト注入。
Slack で会話本文、VS Code で開いているファイル内容の取得を実機確認。

**既知の制約（意図的に先送り）**:
- 「直近の返信対象メッセージ」が抜けることがある（Slack のスレッド末尾、VS Code のチャットパネル等）。
  改善はアプリ個別ルール化しやすく、投資対効果が薄いので、汎用解（LLM による抽出、
  M4 の Vision 連携＝画面キャプチャからの文脈取得）とまとめて再検討する。
- ScreenCaptureKit + Vision フォールバックは未実装（同上、M4 と統合判断）。

**既知の不具合（横断）**:
- アプリ起動直後、右Shift 2回が数回反応しないことがある（2026-07-02 報告）。
  M3-C C5 で対応（同日）: (1) **確定バグ修正** — アクセシビリティ未許可の状態で登録した
  グローバルモニタは許可後も発火しない（初回起動は再起動が必要だった）。許可を監視して
  モニタを再登録するようにした。(2) 間欠ケース向けにジェスチャ受信の診断ログ
  （起動直後の数イベント）を追加。再発したら Console.app の `BombSquad gesture:` で切り分ける。
- 受信モード（transform）は「呼び出し時に選択があった」だけで暗黙に入るため、意図せず入ると
  「送信したのにコピーされる」ように見える（2026-07-02 報告 → 同日、モードバッジ・ボタン文言・
  トースト文言で可視化対応済み。モード切替 UI は M3-C で検討）。
- 管理ウィンドウを開いた状態でパネルを操作すると、操作のたびに管理ウィンドウが前面へ
  引っ張られフォーカスを奪う（2026-07-04 報告・未修正）。原因は `AppDelegate` 各所の
  `NSApp.activate(ignoringOtherApps: true)`（[`showPanel`](../BombSquad/AppDelegate.swift) 等）が
  アプリ全体をアクティブ化し、可視ウィンドウを道連れに前面化させること。README の macOS 方針
  「入力補助のたびに管理ウィンドウへ勝手にフォーカスを移さない」に反する。当面は管理ウィンドウを
  閉じておけば実害なし。修正案: activate の呼び方を見直す／パネル召喚時に管理ウィンドウを
  背面化または一時クローズ。

**目的**: ステートレス脱却の第一歩。最小工数で体感品質を最大に変える。初回ユーザーでも効果が出る。

**スコープ**:

1. **新規サービス `SituationalContextService`**（`BombSquad/Services/`）
   - パネル召喚の瞬間（`AppDelegate.summon()` 内、**パネルがキーウィンドウになる前**）に収集する。
     `SelectionGrabber` の ⌘C 合成と同じタイミング制約（前面アプリがパネルに切り替わる前に読む）。
   - 収集内容:
     - 前面アプリ名・Bundle ID（`NSWorkspace.shared.frontmostApplication`）
     - ウィンドウタイトル（AX API: `kAXFocusedWindowAttribute` → `kAXTitleAttribute`）
     - フォーカス中フィールドの周辺テキスト: AX API でフォーカス要素
       （`kAXFocusedUIElementAttribute`）から親を辿り、`kAXValueAttribute` /
       `kAXSelectedTextAttribute` / static text 子要素を収集して会話スレッドらしきテキストを得る
     - AX で十分なテキストが取れない場合のフォールバック: ScreenCaptureKit
       （`SCScreenshotManager`）で前面ウィンドウのみをキャプチャし、Vision モデルで
       会話コンテクストを抽出（「誰と誰の会話か・直近の話題・トーン」を JSON で返す軽量プロンプト。
       高速モデルを使いレイテンシ 1 秒以内を目標。抽出完了前にレビューが走る場合は L1 なしで実行し、
       完了していれば注入する — ブロッキングにしない）
   - 産物はモデル `SituationalContext`（新規、`BombSquad/Models/`）:
     `appName`, `windowTitle`, `conversationExcerpt`(String, 上限 ~2000 文字), `capturedAt`。
     **永続化しない**（メモリ上のみ、パネルを閉じたら破棄）。

2. **プロンプト注入**（`ReviewPrompt.swift`）
   - `static func contextBlock(_ context: SituationalContext?) -> String` を追加し、
     `system` / `transformSystem` と組み合わせる。内容例:
     「You are assisting inside {appName} ({windowTitle}). The surrounding conversation is: ...
     Use this only to infer recipient, tone, and what is being asked. Do not quote it back.」
   - `ReviewViewModel.runReview()` で `SituationalContext` をプロバイダへ渡す
     （`ReviewProvider.review(...)` のシグネチャに optional 引数を追加）。

3. **プライバシー UI**
   - パネル上部に L1 チップを表示（例: 「📎 Slack — #general の会話を参照中」）。
     クリックで取得内容をポップオーバー表示、「×」で除外（除外したらそのセッションでは注入しない）。

4. **設定**
   - `GeneralSettingsView` に「周辺コンテクストを読み取る」トグル（既定 ON）。
     OFF なら収集自体を行わない。

**非スコープ**: 相手の特定・カード化（M2）、コンテクストの保存、受信モードの変更。

**受け入れ基準**:
- [ ] Slack / Gmail / Mail のスレッド途中で返信を書き、右Shift 2回 → レビュー結果が会話の文脈
      （相手・話題・問われていること）を踏まえた修正になる
- [ ] チップから取得内容を確認・除外できる。除外・設定 OFF 時は従来と同一動作
- [ ] AX が効かないアプリでもフォールバック経由で文脈が入る（またはグレースフルに L1 なしで動く)
- [ ] レビュー開始までの体感遅延が増えない（L1 収集はレビュー実行をブロックしない）
- [ ] `xcodebuild` が通り、アクセシビリティ権限のみで AX 経路が動く（画面収録権限はフォールバック時のみ要求）

### M2: Persona / Relationship メモリとマイページ（L2・L3）

ステータス: 完了（`feature/universal-io` にコミット済み: `ed42931`、2026-07-02 実機確認済み）。
メモリ生成・蒸留の LLM 呼び出しは暫定で Groq `gpt-oss-120b` 直叩き（`MemoryDistiller`）。
M3 の Gateway 移行時にサーバー側へ移す。

**目的**: 人格的一貫性の実体を作り、「使うほど良くなる」と「初回から良い」を両立する。
メモリページを製品の顔にする。

**スコープ**:

1. **データモデル**（ローカル SQLite。`LocalHistoryStore` と同じ流儀で新規 `MemoryStore` を作る）
   ```sql
   CREATE TABLE memory_cards (
       id TEXT PRIMARY KEY NOT NULL,
       kind TEXT NOT NULL,          -- 'persona' | 'relationship'
       subject TEXT,                -- relationship の相手識別子（表示名）。persona は NULL
       content_md TEXT NOT NULL,    -- カード本文（Markdown、ユーザー編集可能）
       source TEXT NOT NULL,        -- 'bootstrap' | 'distilled' | 'user_edited'
       created_at REAL NOT NULL,
       updated_at REAL NOT NULL
   );
   ```
   - M3 で Supabase（`bs_` プレフィックステーブル）へ同期する前提で、スキーマは
     サーバー側と揃えられる素直な形にしておく。

2. **ブートストラップ（オンボーディング）**
   - 管理ウィンドウに「メモリ」タブを新設。空状態では
     「あなたが過去に送ったメール・メッセージを 3〜5 通貼り付けてください」フローを表示。
   - 貼り付けテキストをリッチモデルに渡し Persona Card を生成
     （新プロンプト `PersonaPrompt.bootstrap`: 語彙・文長・敬語傾向・絵文字/記号の癖・
     署名・避けるべき表現を Markdown の定型セクションで出力）。
   - 生成結果をユーザーに見せ、編集して保存できる。

3. **増分蒸留（使うほど良くなる）**
   - Deploy 完了後にバックグラウンドで実行:
     `source_text`（原文）/ レビュー提案 / `final_text`（実際に送った文）の 3 つ組を入力に、
     「ユーザーが AI 提案をどう直したか」から Persona Card への追記候補と
     Relationship Card（L1 で相手が特定できた場合）の更新候補を生成。
   - 自動で即書き換えるのではなく、確度の高い差分のみ適用し、カードの `updated_at` と
     `source='distilled'` を更新。メモリページで変更履歴が分かるようにする（最低限:
     最終更新日時と source 表示）。
   - 実行頻度は Deploy ごと（高速モデルで数百トークンの軽い処理）。失敗しても本体機能に影響させない。

4. **注入**
   - Persona Card は常にシステムプロンプトへ。
   - Relationship Card は L1 の `conversationExcerpt` / `windowTitle` から相手を推定して
     `subject` に一致するカードがあれば注入（推定も蒸留時に高速モデルで実施し、
     カード側に相手のエイリアスを蓄積していく）。

5. **マイページ（管理ウィンドウ「メモリ」タブ）**
   - Persona Card の閲覧・編集（Markdown エディタ＋プレビューで十分）・リセット。
   - Relationship Card の一覧・編集・削除。
   - 「I//O はあなたをこう理解しています」という見出しトーンで、透明性を演出する。
   - 併せて `HistoryPlaceholderView` を実装に置き換え、履歴一覧（before→after diff 表示）を出す。

**非スコープ**: サーバー同期（M3）、embedding 検索（M3 以降）、複数デバイス。

**受け入れ基準**:
- [ ] 新規ユーザーがオンボーディングで過去メールを貼ると、直後のレビューから文体が本人に寄る
      （敬語レベル・署名・語彙が反映される）
- [ ] 同じ相手に数回送ると Relationship Card が生成され、メモリページで確認・編集できる
- [ ] メモリページでカードを編集すると次のレビューに即反映される。削除も可能
- [ ] メモリを全削除すると素の動作に戻る
- [ ] 履歴タブで過去の before→after が diff で見られる

### M3: Gateway 移行・課金・同期

ステータス: M3-A 完了・実機検証済み（2026-07-02、`feature/universal-io` ブランチにコミット済み: `e4e0dd7`）。
**決定（2026-07-02、オーナー確認済み）**: Gateway は FastAPI ではなく
**Next.js Route Handlers（`web/`、Vercel）**。既存の
[old/auth-billing-infra-plan.md](old/auth-billing-infra-plan.md)・[api-contract.md](api-contract.md)・
適用済み Supabase スキーマ（`bs_` テーブル群）に従う。段階分割で進める:

- **M3-A（完了・実機検証済み）**: `web/app/api/ai/review` Gateway（Supabase JWT 検証、
  テナント解決、無料枠クォータ 50/月、Groq/OpenAI 呼び出し、`bs_usage_events` 記録）＋
  macOS `GatewayReviewClient`（既定。BYOK 直叩きは Gateway 未設定時のフォールバック）。
  context/memory はリクエストで受け取りプロンプトにのみ使用（保存しない、契約書参照）。
- **M3-B（実装中、`feature/universal-io`）**: Stripe 課金（アカウント構造はオーナー整理待ちのため
  最後に回す）、クォータ UI、Vision/ASR/メモリ蒸留の Gateway 移行、メモリ同期。
  macOS 側は `GatewayAPI` に共通化し、BYOK 直叩きは従来どおりフォールバック。
  ASR/Vision/蒸留にハードクォータは未設定（使用量記録のみ。上限は Stripe プラン導入時に設定）。
  実機確認済み（2026-07-02、ローカル Gateway `npm run dev` + macOS アプリ）:
  - ASR（`/api/ai/transcribe`）: 右Shift長押しの音声入力→文字起こし→レビューまで成功
  - Vision（`/api/ai/vision`）: 空欄で右Shift2回→撮影→読み取り成功。マイページの利用量カウントも確認
  - メモリ bootstrap（`/api/ai/memory/distill`）: プロファイル生成成功。生成ボタンは
    貼り付けが50文字未満だと無効化される仕様だが、理由の表示が無く分かりにくかったため、
    不足文字数のヒント表示を追加（[`MemoryView.swift`](../BombSquad/Views/Management/MemoryView.swift)）
  - メモリ post-deploy distillation（送信後の自動学習）は未確認（別途確認予定）
  - **メモリ同期（2026-07-03 完了・実機確認済み）**: `bs_memory_cards`（tombstone 付き、
    user スコープ RLS。migration `0002_bs_memory_cards.sql`）＋ Gateway `GET/PUT /api/memory/cards`
    （`updated_at` 勝ちマージ、PUT 1往復で push+pull 完結、削除は tombstone 伝搬）＋
    macOS [`MemorySyncService`](../BombSquad/Services/MemorySyncService.swift)（起動時＋編集時
    2.5秒デバウンス同期、Gateway 未設定/未ログイン時は no-op）。実機で起動時同期・編集同期・
    ループ無しを確認。検証中に発見・修正した 2 件: (1) 通常起動は `.signedIn` でなく
    `.initialSession` イベントで復元されるため起動時同期が発火しなかった、(2) Swift の
    `UUID().uuidString` は大文字・Postgres uuid は小文字を返すため、同期のたびカードが二重化
    （生成時小文字化＋既存 ID 正規化マイグレーションで解消）。
  残り: Stripe 課金（アカウント構造オーナー整理待ち）。

  **Gateway 本番デプロイ（2026-07-03 着手、引き継ぎ中）**:
  - 決定事項: 製品サイト `universal-io.com`（既存 Vercel プロジェクト、`web-product` リポジトリ）
    とは**別の Vercel プロジェクト**を新規作成し、Gateway (`app-mac` リポジトリの `web/`) を
    **`api.universal-io.com`** サブドメインへ配置する（apex は 2 プロジェクトに同居できないため）。
    URL 構造は `api.universal-io.com/api/ai/review` のように `/api` が二重に見えるが、
    ルート移動はせずこのまま採用（オーナー決定：実機確認済みの経路を変えるリスクを避ける）。
  - macOS クライアントの本番向き先は設定済み: [`project.yml`](../project.yml) の Info.plist に
    `BOMB_SQUAD_API_BASE_URL: https://api.universal-io.com` を既定値として追加
    （[`BombSquadConfig`](../BombSquad/Services/BombSquadConfig.swift) の読み込み順は
    `BombSquad.local.plist`（開発者のlocalhost）→ Info.plist の順なので、開発中は影響なし）。
  - **詰まった問題と原因（解決済み）**: Vercel で「Root Directory=web」を設定しても
    `Error: No Output Directory named "public" found` が繰り返し発生した。原因は
    **`feature/universal-io-m4` ブランチの内容が一度も GitHub へ push されていなかったこと**。
    Vercel が見ていた GitHub の `main` は 2026-07-02 の古いコミット（`d989bf2`）のままで、
    Gateway の API 実装（`web/app/api/*` 一式）がそもそも存在しなかった
    （ページ・認証・料金表のみで review/vision/transcribe/memory の route.ts が無い）。
    Vercel の「public を探す」挙動は、実際には正しい Next.js ビルド出力があるにもかかわらず、
    その手前でビルドしていたコード自体が不完全だったことに起因する一連の紛らわしい表示だった。
  - **対処済み（2026-07-03）**: `feature/universal-io-m4` を `main` へ fast-forward マージし
    `origin/main` へ push 済み（コミット `a2bbef4`）。新しいブランチは作成していない。
  - **デプロイ成功・ドメイン割り当て完了（2026-07-03）**: `https://api.universal-io.com/` が
    本番稼働中（トップページ 200、`/api/ai/review` は未認証で 400 を返す＝Gateway 自体は正常）。
  - **既知の不具合（未解決）**: Web の `/auth` ページで「Google でログイン」を押すと
    Internal Server Error になる。切り分け済み: (1) `NEXT_PUBLIC_SUPABASE_URL` 等は本番ビルドの
    JS に正しく埋め込まれている（client 初期化は原因ではない）、(2) Supabase の
    `/auth/v1/authorize` は正常に Google の同意画面へ 302 リダイレクトしている（Google Cloud
    OAuth クライアント自体は生きている）。**濃厚な原因**: [supabase-setup.md](supabase-setup.md)
    の Redirect URLs に **`https://api.universal-io.com/auth/callback` が未登録**
    （ドメインは今日新規に確定したため）。Google 承認後、Supabase がこの URL へ戻そうとして
    許可リストに無く弾かれている可能性が高い。**対処**: Supabase Dashboard →
    Authentication → URL Configuration → Redirect URLs に
    `https://api.universal-io.com/auth/callback` を追加（→ 追加後 supabase-setup.md も更新）。
    追加後に実機で再確認すること。
  - **完了（2026-07-04）**:
    1. Redirect URLs 追加と Web の Google ログイン修正（前セッション `0a3dd60`）。
    2. macOS クライアントの本番疎通を実機確認（配布ビルド相当＝local.plist の
       `BOMB_SQUAD_API_BASE_URL` を空にして Info.plist の `https://api.universal-io.com` へ
       フォールバックさせたビルドで、ログイン＋レビューが本番 Gateway 経由で成功）。
       本番各エンドポイント（review/vision/transcribe/memory）も未認証で正常応答を確認。
       確認後 local.plist は localhost へ復元済み。**開発時の注意**: 確認中に
       ローカル Gateway（localhost:3000）が HTTP 500 を返していた（`web/` の `npm run dev` 要確認）。
  - **次のセッションでやること**:
    1. Stripe: `.env.local` に `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` はまだ未設定
       （テストモードで実装先行の方針）。Webhook エンドポイントは
       `https://api.universal-io.com/api/stripe/webhook` で登録し、
       secret を発行してから Vercel の環境変数へ追加する。価格は Standard ¥1,980 / Pro ¥4,980。
       `bs_entitlements.plan` の CHECK 制約に `standard` を追加するマイグレーションが必要
       （現状 `free/pro/team/enterprise` のみ）。
  - **リリース前に忘れてはいけないこと**: `BombSquad.local.plist` はアプリバンドルに同梱され
    最優先で読まれるため、配布ビルドを作る前に同ファイルの `BOMB_SQUAD_API_BASE_URL` を空にし、
    Info.plist の本番既定へ確実にフォールバックさせること（README の「セットアップ」節に
    注意書き済み）。

- **M3-C（実装中、`feature/universal-io`、2026-07-02 着手）**: パネル UI 刷新。
  デザイン原則 3.5 を全面適用する。フェーズ分割:
  - **C1 情報設計**: パネルを Spotlight/Raycast 型の縦 1 カラム（1 入力欄＋結果、
    空 → 原文 → 結果の 3 状態）に再構成。出力言語プルダウンをパネルから撤去し
    設定へ移動＋UserDefaults 永続化（「セッションごとに日本語へ戻る」既知課題も解消）。
    diff を結果表示の中心に昇格。右Shift 1回のフォーカス切替は上下（原文↔結果）として維持。
  - **C2 ストリーミング**: Gateway `/api/ai/review` に SSE を追加（`stream: true`）。
    revised_text の増分を `delta` イベント、最後に `result`（全体 JSON + quota）。
    macOS 側は `GatewayReviewClient` にストリーミング経路、結果エディタへトークン単位で反映。
    BYOK フォールバックは非ストリーミングのまま。
  - **C3 Liquid Glass / ビジュアル**: パネルをタイトルバーレスの浮遊ガラスに。
    `glassEffect`（macOS 26+、`#available` でフォールバック=現行 material。
    デプロイターゲットは 14.0 のまま）。メニューバーをモノクロ I//O グリフに。
    アニメーションはシステムスプリング/クロスフェードのみ。VoiceOver ラベル整備。
  - **C4 リブランド第 1 段**: 表示名・ウィンドウタイトルを Universal I/O 系へ。
    Bundle ID / URL scheme 変更は Supabase Redirect URL 設定と Keychain/権限の
    再許可を伴うため、変更内容をオーナーに提示して確認後に実施。
  - **C5 既知バグ**: アプリ起動直後に右Shift 2回が数回反応しない問題の切り分けと修正
    （M1 の「既知の不具合」参照）。
  実施順: C1 → C2 → C3 → C5 → C4。
  進捗（2026-07-02）: C1・C2・C3・C5 実装済み・**実機確認済み**（同日、レイアウト3状態・
  SSE ストリーミング・Liquid Glass・起動直後ジェスチャをすべて確認）。
  C4 は表示層（CFBundleDisplayName・ウィンドウタイトル・メニューバーグリフ）に続き、
  **Bundle ID / URL scheme も変更済み**（2026-07-03 オーナー決定: ドメイン
  `universal-io.com` の逆引きで `com.universal-io.mac` ／ scheme `universal-io://`。
  Keychain は legacyServices フォールバックで旧キーを引き継ぎ）。初回起動時に
  アクセシビリティ／マイク／画面収録の再許可と再ログインが必要。Supabase の
  Redirect URLs に `universal-io://auth/callback` の追加が必要（オーナー作業）。
  関連決定（同日）: Stripe はテストモードで実装先行、価格は Standard ¥1,980 /
  Pro ¥4,980。**Gateway デプロイ構成（2026-07-03 決定）**: 製品サイトは
  `universal-io.com`（既存 Vercel プロジェクト、web-product リポジトリ）で稼働中。
  Gateway は**別 Vercel プロジェクト**に分離し `api.universal-io.com` サブドメインへ
  （GitHub 連携 = app-mac リポジトリ、Root Directory=`web`）。apex を 2 プロジェクトに
  当てられないためサブドメイン分離が必須。クライアントの本番向き先デフォルトは
  Info.plist に `https://api.universal-io.com` を設定済み（開発は local.plist の
  localhost が優先。`GatewayAPI.endpoint` が `/api` 有無を吸収）。メールは
  Cloudflare + Resend 予定。

**目的**: ビジネス成立の土台。API キーのクライアント撤去、メータリング、Stripe サブスク、
デバイス間メモリ同期。**リブランドに伴う Bundle ID 変更もここで同時に行う**
（Keychain / 権限再許可の痛みを 1 回で済ませる）。

**スコープ**:

1. **Gateway（Next.js Route Handlers。既存 [old/auth-billing-infra-plan.md](old/auth-billing-infra-plan.md) と整合させて更新）**
   - エンドポイント（Pydantic スキーマ必須、[api-contract.md](api-contract.md) を正本として更新）:
     - `POST /v1/transform` — 送信レビュー／受信変換／Vision 解釈を統合した変換 API
       （`mode`, `input`, `situational_context`, `output_language`, ストリーミング=SSE）
     - `POST /v1/transcribe` — ASR プロキシ
     - `GET/PUT/DELETE /v1/memory/cards` — メモリ同期
     - `POST /v1/memory/distill` — 蒸留ジョブ
     - `GET /v1/me` — プラン・使用量
   - 認証: Supabase JWT 検証。使用量は `bs_usage_events` に記録（tokens, model, feature）。
   - モデルルーティング: プラン × 機能 × レイテンシ要件でサーバー側設定から決定。
     クライアントからモデル指定は受け取らない（開発者フラグ除く）。
   - Anthropic 連携の実装詳細（モデル ID・ストリーミング・Tool Use）は実装時に
     最新の公式ドキュメントを確認すること。
2. **Stripe 課金**: Standard / Pro の 2 プラン＋トライアル
   （オンボーディング〜最初の数変換まで無料）。Webhook で `bs_subscriptions` を更新。
   `PricingView` を実装に置き換え、アプリ内からは Web の課金ページへ誘導
   （macOS 直販アプリなので IAP 不要）。
3. **クライアント移行**: `GatewayReviewProvider: ReviewProvider` / `GatewayVisionProvider` を
   実装し既定に。SSE ストリーミングをパネル UI に反映（結果がトークン単位で流れる）。
   Keychain BYOK は隠し開発者設定に格下げ。`MemoryStore` を Supabase 同期対応にする
   （ローカルキャッシュ＋起動時/変更時同期。競合は updated_at 勝ち）。
4. **パネル UI の切り詰め（デザイン原則 3.5 の適用)**: モデル・言語プルダウンをパネルから
   管理ウィンドウへ移動。ストリーミング表示と diff を中心に再構成。
   Liquid Glass 採用（デプロイターゲット判断含む）。
5. **リブランド第 1 段**: Bundle ID / Keychain service / 表示名を Universal I/O 系に変更
   （コード名前空間のリネームは任意。表示層だけでもよい）。

**受け入れ基準**:
- [ ] クライアントバイナリに LLM プロバイダのキーが存在しない
- [ ] 未課金ユーザーはトライアル分だけ変換でき、超過で課金導線に誘導される
- [ ] 使用量が `bs_usage_events` に記録され、`/v1/me` とマイページで見える
- [ ] レビュー結果がストリーミング表示される（最初のトークンまで体感 1 秒以内）
- [ ] メモリカードが 2 台の Mac 間で同期される
- [ ] パネルにプルダウン類がなく、空→原文→結果の 3 状態だけで完結する

### M4: Vision の再定義 —「見る → わかる → 返す」

> ⚠️ **世代注記（2026-07-13）**: 本節は M4 完了時点（2026-07-03）の記録。**2026-07-07 の
> Navigator v3 以降、キャプチャ直後の既定挙動は Navigator セッション（軽い現状認識 →
> 質問チャット → コパイロット）に置き換わり、本節のフル解釈フローは Navigator 利用不可時の
> フォールバックに降格した**。現在の挙動の正本は
> [copilot-challenge-3.md](copilot-challenge-3.md)、コードの正は
> `ReviewViewModel.enterVisionMode`。本節を「現在の Vision の仕様」として移植・実装しないこと
> （foundation-rebuild-plan.md §3 移植規律 6 の事故事例参照）。

ステータス: スコープ 1〜3 完了・**実機確認済み**（`feature/universal-io-m4`、2026-07-03。
受け入れ基準 4 項目＋キャプチャ UX を実機で確認）。スコープ 4（受信変換の統合）は
別フェーズ（M4-B）として続行中。

進捗（2026-07-03）: スコープ 1〜3 実装・実機確認済み。実装メモ:
- キャプチャ（2026-07-03 オーナー仕様確定で改修）: 右Shift2回で
  `ScreenshotSelectionOverlay` が開き**全画面が選択済み**の状態で待機。Enter =全画面確定、
  ドラッグ=範囲選択（`captureRegion`）、esc =パネルへ戻る、右Shift2回=セッション破棄で
  待機モードへ。実撮影は `ScreenshotCaptureService`（SCScreenshotManager、カーソルの
  ディスプレイ。5K 級はアップロード上限対策で半分に縮小）。SCK 失敗時のみ
  `screencapture -i` にフォールバック。
- スキーマ: `VisionInterpretationResult` を situation / extracted / asks /
  suggested_actions[{title, kind, draft}] に刷新（旧 summary / visible_text 形も
  `decodeFlexible` で受容）。Gateway `/api/ai/vision` は review と同じ
  `input.context` / `input.memory` を受け取りプロンプトにのみ使用
  （[api-contract.md](api-contract.md) 更新済み）。BYOK `OpenAIVisionClient` も同等。
- UI: `VisionPanelView` 右ペインを状況→求められていること→提案アクション（カード）→
  読み取った内容に再構成。文案付きアクションは「承認して送信」（PasteDeployer で呼び出し元へ
  注入→パネル閉）と「編集する」（compose エディタへ引き継ぎ。パネルは 1 カラム幅へ復帰）。

**目的**: Vision を「スクショ → OCR → コピー」の素材撮影から、北極星体験
（画面を見せるだけで、やるべきことと文案が用意され、承認するだけ）の初期形へ引き上げる。

**スコープ**:

1. **キャプチャの刷新**（2026-07-03 オーナー仕様確定）: 空の原文欄で右Shift 2回 →
   **選択オーバーレイが全画面選択済みの状態で開く**。Enter でそのまま全画面を確定
   （ScreenCaptureKit、カーソルのあるディスプレイ。「今見ている画面」をそのまま渡す）、
   ドラッグで従来どおり範囲選択、esc でパネルへ戻る、右Shift 2回でセッション破棄
   （パネルが出る前の待機モードへ）。ユーザー操作は「呼び出す→ Enter」の 2 手に収める。
2. **解釈スキーマの拡張**（`VisionInterpretationResult` を拡張）:
   ```json
   {
     "situation": "この画面で何が起きているかの要約（1-2文）",
     "extracted": "画面から読み取った本文（構造化 Markdown）",
     "asks": ["あなたに求められていること（依頼・期限・事実）"],
     "suggested_actions": [
       {
         "title": "田中さんへ返信する",
         "kind": "reply | fill_form | task | info_only",
         "draft": "kind=reply の場合、Persona/Relationship を反映した返信文案"
       }
     ]
   }
   ```
   - 生成には Persona Card / Relationship Card / L1 を注入する（M1・M2 の成果を接続）。
3. **Vision パネル UI**: 左=スクリーンショット、右=「状況 → 求められていること →
   提案アクション（カード形式）」。reply 系アクションは
   **「承認して送信」＝そのまま Deploy** と **「編集する」＝compose モードへ文案を引き継ぎ**
   の 2 ボタン。ここで Vision → Voice/テキストのループが閉じる。
4. **受信変換の統合（M4-B。2026-07-03 実装済み・実機確認済み）**: transform モード
   （選択テキスト取り込み）を Vision 解釈の特殊ケースとしてスキーマ・UI を共通化。
   実装メモ:
   - Gateway `/api/ai/vision` が `input.text`（受信メッセージ、最大16,000字）を
     `image_base64` と排他で受ける（[api-contract.md](api-contract.md) 更新済み）。
     text の場合、`extracted` は「攻撃性・感情・皮肉を除いた中立な整理版」。
     BYOK `OpenAIVisionClient` も同等実装。
   - macOS: transform の変換は `runReview()` 内で解釈経路へ分岐
     （`runTransformInterpretation`、SSE レビュー経路は compose 専用に）。右ペインは
     Vision と同じ「状況→求められていること→提案アクション→整理した内容」。
   - **出口原則は不変（書き戻さない）**: transform の提案アクションは
     「承認してコピー」＝クリップボードのみ。「編集する」（compose への引き継ぎ）は
     デプロイヤ／プロンプトの整合が必要なため transform では非表示（次段候補）。
   - UI 切り詰め（同日オーナー指示）: 受信側はペインタイトル・文字数・説明バナー・
     レビュー/コピー/カメラ/ヘルプボタンを撤去し、受信メッセージは**読み取り専用**。
     残る操作は右ペインの「コピー」と「承認してコピー」のみ。あわせて compose の
     青フォーカスリングは「原文 vs 結果の二者択一になった時だけ」表示に変更。
   - 返信文案の役割取り違え（相手の行動を自分の行動として書く）を役割固定
     プロンプトで修正（受信者視点の明示＋依頼ゼロのメッセージへは短い承知で返す）。
   - 旧 transform 表示（IssueCard の受信ラベル・transformSystem プロンプト）は
     未使用化。掃除は M5 リブランド時にまとめて行う。

**非スコープ**: 画面の常時監視、複数アクションの自動実行、reply 以外のアクションの実行
（fill_form / task は表示と文案・手順の提示まで）。

**受け入れ基準**（2026-07-03 実機確認済み）:
- [x] メール画面を開いて右Shift 2回（空欄）→ Enter で「状況・求められていること・返信文案」が出る
- [x] 「承認して送信」でメールの返信欄に文案が注入される（ユーザーの追加入力ゼロ）
- [x] 文案にユーザーの文体（Persona）と相手との関係性（Relationship）が反映されている
- [x] info_only の画面（エラー・外国語 UI 等）では「わかる」まで（要約と次の一手の提示）が機能する

### M4 の先（ピン留め、2026-07-03 オーナー確認）: Vision 完成形と波の観測

**完成形（プロダクトのゴール）**: 「理解の代理」と「操作の代理」の合成レイヤー＝**認知の義肢**。
スクリーンショット（既定は全画面）を撮るだけで、今見ている画面を解釈・整理し、
アクションに落とし込み、ユーザーは AI の提案するアクションを**承認していくだけ**。
役所の申請・病院の Web 問診・各種手続き・会計ソフト・アクセス解析などを、
認知的・能力的ギャップがある人でも最低限こなせるようにする。秘書ではなく**本人の代理**。
自動実行はせず承認駆動（1.2 の北極星と同一原則）。

**方針**: 実装は常に「現在の技術で実際に機能する一番近い形」に留める。精度の低い段階の
技術（汎用 GUI grounding 等）には手を出さず、壁が崩れた瞬間に打ち出せるよう仕込みを先行させる。

**完成形までの階段**（各段は前段が実機で機能してから）:
1. **M4（実装済み・検証待ち）**: 全画面 1 ショット → 状況・asks・文案付きアクション → 承認で ⌘V 注入
2. **Vision × AX の fill_form**: 「何を書くか」= Vision、「どこに書くか」= AX API。
   モデルの座標 grounding を待たずに今日の技術で成立する中間解
3. **タスクセッション**: 複数画面にまたがる手続きの計画・進行状態・ステップごとの再キャプチャと検証
4. **パーソナルデータボールト**: 氏名・住所等の構造化本人データ＋利用ごとの承認 UI（役所・問診の解錠鍵）
5. **汎用エグゼキュータ**: computer use 系 API への実行部差し替え（スキーマ・UX は不変のまま）

**波の観測（2026-07-03 時点の読み）**:
- **GUI エージェント能力**: OSWorld-Verified で Claude Opus 4.8 = 83.4%、Fable/Mythos 5 ≈ 85% と
  **人間ベースライン（≈72%）を既に超えた**。能力の壁は崩れつつあり、残る壁は主にコストと統合。
  Anthropic の computer use ツール（`computer_20251124`、beta）が標準インターフェース候補。
- **コスト**: 単発 Vision 解釈は 1 円未満〜数円で既に問題なし。エージェント型手続き 1 件は
  Sonnet 5 級で概算 ¥50〜150（プロンプトキャッシュ込み）。「1 手続き ¥10 台」がマス展開の合図。
- **トリガー**: 私設ベンチ（下記）で「初見フォーム記入のステップ精度 ≈95%」を新モデルが超えた時点で
  階段 5 に着手。
- **仕込み（優先）**: ①私設ベンチ＝波検知器（役所・問診・会計・解析の実画面＋期待アクションの
  ゴールデンセット）を早期に作る、②アクションスキーマをエグゼキュータ非依存に保つ、
  ③Persona/Relationship/本人データのボールト、④承認 UX の文法。

**モデル選定（2026-07-03 リサーチ。適用はオーナー判断）**:
- Vision 解釈＋文案生成の品質本命: **Claude Sonnet 5**（$3/$15、2026-08 まで導入価格 $2/$10。
  高解像度ビジョン 2576px・指示追従・日本語品質。Gateway に Anthropic エンジン追加が必要）。
  現行の OpenAI `gpt-5.4-mini`（$0.75/$4.5）は速度・コストの現実解として妥当。
  フォールバック `gpt-4.1-mini` は旧世代のため `gpt-5.4-nano` 等へ更新推奨。
- ASR: Groq `whisper-large-v3` は現役。より高速な `whisper-large-v3-turbo` が Groq 推奨の移行先。
- ローカル VLM（Qwen3-VL 等）はサーバー級では商用に肉薄。コンシューマ Mac での文案品質は
  まだ先＝プライバシー切り札は引き続き観測。

### M5: マルチデバイス展開・リブランド完了

**目的**: iOS カスタムキーボードの GA と Universal I/O 正式リブランド。

**スコープ（概要。着手時にこのセクションを詳細化すること）**:
- iOS: `app-ios/BombSquadKeyboard` を Gateway 接続に対応。キーボードがモバイルの
  I//O レイヤーの物理的正位置。共有シート＋ショートカット対応。
  キーボード拡張のメモリ・ネットワーク制約（Full Access）に注意。
- macOS: Accessibility API による実フィールド直接注入（`Deployer` 差し替え、
  クリップボード退避の廃止）。
- リブランド完了: 名称・ロゴ（I//O）・Web・ストア表記の統一。
- Windows / Android は調査から。

### M5 の先行検討（ピン留め、2026-07-04）: Android 展開の見立て

まだリポジトリも無い構想段階だが、プラットフォーム能力の評価をここに記録する。
結論: **Android は macOS 同等どころか、いくつかの次元で macOS を超える I//O が作れる**。
iOS と対照的に、必要な「穴」がすべて公式 API として存在する。

**macOS 同等が成立する対応表**:

| I//O の要素 | macOS 実装 | Android 対応物 |
|---|---|---|
| グローバル召喚 | 右Shift2回（AX イベント監視） | **デフォルトアシスタント枠**（電源長押し/コーナースワイプ。VoiceInteractionService）、フローティングバブル、クイック設定タイル |
| 画面キャプチャ | ScreenCaptureKit | MediaProjection（ユーザー同意でセッション型キャプチャ） |
| 周辺文脈の取得（L1） | AX API のツリー探索 | **AccessibilityService**（全アプリの UI ツリー読取。イベント駆動で変化通知まで来る） |
| フィールド注入 | ⌘V 合成（AX 直接注入はロードマップ） | **ACTION_SET_TEXT で直接注入が今日できる**（Mac で未達の本筋が Android では標準機能） |
| 浮遊パネル | NSPanel | オーバーレイ（SYSTEM_ALERT_WINDOW「他のアプリの上に重ねて表示」） |
| 選択テキスト取り込み | ⌘C 合成 | **ACTION_PROCESS_TEXT**（全アプリの選択メニューに「I//O で読む」を出せる） |

**macOS を超え得る点**:
1. **デフォルトアシスタント枠**: ユーザーが I//O を端末のアシスタントに設定すると、
   OS 公認のグローバルジェスチャで召喚され、**その瞬間の画面内容（AssistStructure =
   ビュー階層）とスクリーンショットが OS から渡される**。Gemini が座っている椅子に
   サードパーティが座れる（前例あり）。「召喚＋見る」が OS 公式で 1 ジェスチャ。
2. **Notification Listener**: 全アプリの通知（受信メッセージ本文）をリアルタイム取得。
   **受信側がキャプチャ不要・選択不要で成立**する。攻撃的メッセージを通知段階で
   中立版に変換して見せる「受信フィルター」は Android でしか作れない。
3. **IME（キーボード）が iOS の制約なし**: メモリ上限の崖なし、キーボード内から
   マイク録音可（アプリ往復不要）、任意 UI 展開可。iOS で設計した app-assisted 構成が
   不要になり、キーボード単体で「喋る→トゲ取り→注入」が完結する。
4. **常時文脈エンジン**: AccessibilityService はイベント駆動で画面変化を受け取れるため、
   スクショに頼らず L1 コンテクストを常時・低コストで維持できる。
5. **Autofill Framework**: fill_form（M4 の先・階段 2）の公式 API が存在する。
6. **配布の逃げ道**: 最悪 Play 審査に通らなくてもサイドロード配布が合法的に可能
   （iOS には無い選択肢）。

**戦略上の急所（好材料）**: AccessibilityService は Google Play ポリシーで用途申告が
必要で、非アクセシビリティ用途の濫用は却下される。しかし **I//O は製品テーゼ自体が
アクセシビリティ（認知の眼鏡・補聴器・義肢）**であり、この権限を最も正直に主張できる
プロダクトに属する。多くのアプリにとって障壁であるものが、I//O には参入障壁（堀）として働く。

**リスク・制約**:
- FLAG_SECURE ウィンドウ（銀行アプリ等）はキャプチャ・AX 読取とも不可。
- OEM 断片化: 中華系端末のバックグラウンド強制終了、ジェスチャ差異。
- 「ユーザー補助」権限の警告文言が強く、オンボーディングでの信頼設計が必須
  （プライバシー原則 §3.4 をそのまま前面に）。
- Play の AccessibilityService 審査は年々厳格化しており、申告・動画・用途説明の
  準備コストは見込むこと。

**示唆**: 北極星体験（見せる→承認するだけ）に最も早く・最も完全に到達できる
プラットフォームは Android の可能性がある。タブレットも同一 API（+ DeX 等の
デスクトップモード）でカバーされる。Gateway・スキーマ・Persona/Relationship は
そのまま共用（§1.5 の設計どおり）。着手時はデフォルトアシスタント枠＋
AccessibilityService の POC から。

**オーナー決定（2026-07-04）: Android を今後重要視する**
- 次の一手は手元の Xiaomi Android タブレット（実売 ~1 万円）での検証。着手前に
  「あるべき姿」を定義する。
- **Android で「本当にやりたいこと」がすべて成立するなら、Android をメインに据えて
  よい**。Mac 版を捨てるのではなく、PC でできること（業務ハーネス）は PC に残した上で、
  個人向け = Android という切り分けもあり得る。
- ビジネスモデル拡張: 安価なハードウェアを活かした
  (a) **ディスアビリティ解決が必要な現場へのデバイスごとの導入**、
  (b) **フルマネージドのデバイス付きサービス（SaaS ＋ハードウェア）**。
- マネージドデバイスモデルの技術的裏付け: Android Enterprise（専用デバイスモード・
  ゼロタッチ登録・MDM）が公式に存在し、権限（ユーザー補助等）を事前構成して出荷できる。
  このモデルでは Play 審査すら不要（管理配布で完結）で、Android 最大の UX 障壁
  （ユーザー補助権限の警告への信頼形成）が消える。「アプリを入れてもらう」から
  「理解が組み込まれたデバイスが届く」へ、GTM が反転する。

**あるべき姿（たたき台、2026-07-04。着手時にこれを叩いて正本化する）**:

> そのタブレットを持つ人にとって、世界との全ての意味的な出入りが I//O を通る。
> デバイスは「認知の義肢」そのものであり、アプリではない。

1 台の Android デバイス上で I//O が **4 つの座席**を同時に占める:

| 座席 | Android API | 提供する体験 |
|---|---|---|
| **目**（見る→わかる） | デフォルトアシスタント枠 | ボタン長押しで、今見ている画面の意味・求められていること・次の一手が出る |
| **耳**（受信フィルター） | Notification Listener | 攻撃的・難解なメッセージが、届く前に中立で分かりやすい形に変換されて通知される |
| **口**（入力・トゲ取り） | IME（キーボード） | 喋る/打つ→整えられた文が出ていく。iOS の app-assisted 構成が不要で単体完結 |
| **手**（承認駆動の実行） | AccessibilityService＋Autofill | 提案アクションを承認するとフォームに直接書き込まれる |

Mac は「目」「口」を別ジェスチャで実現し「手」は未達、iOS は「口」しか取れない。
**4 座席全部を占有できるのは Android だけ**。これが「本当にやりたいことがすべて
できるか」の検証項目そのものになる。

プラットフォームの切り分け（現時点の整理）:

| | 役割 | 対象 |
|---|---|---|
| **Android** | 完全形の認知の義肢。個人・現場・デバイス込み | 個人利用、支援現場（施設・学校・家庭） |
| **Mac** | 業務ハーネス（PC 作業の文脈で価値が立つ） | PC で仕事をする人 |
| **iOS** | 入力の瞬間のみ（キーボード。受信側は優先度低 = `app-ios/docs/receiving-side-options.md` §0） | iPhone ユーザーの補完 |

着手時の次の一手:
1. Xiaomi タブレットの素性確認（Android バージョン、HyperOS/MIUI のバックグラウンド
   制約。Xiaomi は制約が厳しい代表格なので試金石として適切）。
2. POC: 検証価値が最も高いのは「目」（アシスタント枠で画面内容＝ AssistStructure が
   本当に渡るか）と「手」（ACTION_SET_TEXT で LINE 等へ注入できるか）。この 2 つが
   通れば Mac 超えが確定する。Gateway はそのまま使えるため POC は薄い Kotlin アプリ 1 つ。
3. `app-android` リポジトリを新設し、このたたき台を README / マスタープランとして正本化。

---

## 6. マイルストーン間の依存関係

```
M1 (L1 コンテクスト) ──┬──> M2 (メモリ/マイページ) ──> M3 (Gateway/課金) ──> M5 (マルチデバイス)
                        └──────────────────────────────> M4 (Vision 再定義)
```

- M4 は M1・M2 の成果（コンテクスト・ペルソナ注入)を文案生成に使うため、M2 完了後が望ましい。
  M3 と M4 は並行可能だが、M4 の Vision 呼び出しコストが大きいため課金（M3）を先行させる。

## 7. このドキュメントの運用

- マイルストーン開始時: 対象セクションに `ステータス: 実装中（ブランチ名）` を追記する。
- 完了時: 受け入れ基準のチェックボックスを埋め、`ステータス: 完了（マージコミット）` にする。
- 方針変更時: 該当セクションを書き換え、冒頭の「最終更新」を更新する。旧記述は残さない
  （経緯は git 履歴が持つ）。
