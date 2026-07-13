# ドキュメント索引（単一の入口）

最終更新: 2026-07-13（全ドキュメント鮮度監査を実施。M4 世代の Vision 記述・BYOK 世代の
モデル記述・0001 世代の DB 記述など「古い記述が仕様として誤読される」箇所を一掃）

> 🔴 **仕様の優先順位**: 2026-07-13 に新 `SessionCoordinator` 経路へ切替済みで、現在の
> `BombSquad/Core/` が実装の正。Phase 3 の移植パリティを再確認する場合だけ、削除直前の旧経路を
> `git show a0f928e:BombSquad/ViewModels/ReviewViewModel.swift` 等で参照する。

**新しいセッション・新しい開発者は、コードに触る前に必ずこのファイルを読むこと。**
ここに載っていないドキュメントは `docs/` に存在してはならない（存在したら索引への登録漏れ = 直す）。

## 読む順番（新規セッションの立ち上げ）

1. [../README.md](../README.md) — 製品と現行実装の仕様
2. このファイル — どのドキュメントが正本かを把握
3. [foundation-rebuild-plan.md](foundation-rebuild-plan.md) — **今やっている作業の正本**
4. 作業対象に応じて下表の該当ドキュメント

## 正本（living documents — 役割ごとに1つだけ）

| ドキュメント | 役割 | 状態 |
|---|---|---|
| [foundation-rebuild-plan.md](foundation-rebuild-plan.md) | 基盤作り直し（シャーシ交換）の計画と完了記録 | Phase 4 完了・統合待ち |
| [manual-golden-paths.md](manual-golden-paths.md) | 手動検証チェックリスト（GP-01〜27）。フェーズ完了ごとに実施 | 現役 |
| [universal-io-master-plan.md](universal-io-master-plan.md) | 製品ビジョン・アーキテクチャ・マイルストーン（M1〜M5）の正本 | 現役 |
| [api-contract.md](api-contract.md) | クライアント⇔Gateway の API 契約の正本 | 現役 |
| [navigator-copilot-plan.md](navigator-copilot-plan.md) | Navigator/Copilot 機能の設計正本 | 現役 |
| [navigator-stabilization-followups.md](navigator-stabilization-followups.md) | **現行開発の正本**。Copilot のモデル選定・画面遷移検出・精度検証 | 開始準備完了 |

## 参照資料（安定・変更頻度低）

| ドキュメント | 役割 |
|---|---|
| [supabase-setup.md](supabase-setup.md) | Supabase の設定手順（URL・マイグレーション・認証・Redirect URLs） |
| [admin-dashboard-plan.md](admin-dashboard-plan.md) | Admin Console の設計記録（v0 実装済み・本番稼働中。v1 は未着手） |
| [pitch/](pitch/) | ピッチ・GTM 戦略の議論ログ（layer-value-thesis / vision-and-dev-direction / investor-pitch-v1） |
| [promo/](promo/) | 紹介ビデオのシナリオ（コンシューマー版・B2B 版） |

## アーカイブ（docs/old/ — 歴史。現状把握のために読む必要なし）

| ドキュメント | 何だったか / 後継 |
|---|---|
| [old/implementation-roadmap.md](old/implementation-roadmap.md) | 旧実装ロードマップ。凍結済みで現状と不一致 → 後継: foundation-rebuild-plan.md |
| [old/auth-billing-infra-plan.md](old/auth-billing-infra-plan.md) | 認証・課金の設計草案 → 後継: api-contract.md（契約）+ 実装そのもの |
| [old/foundation-recovery-handoff.md](old/foundation-recovery-handoff.md) | ビッグバン失敗からのリカバリ記録（クローズ） → 後継: foundation-rebuild-plan.md |

リポジトリに無い歴史資料: 旧リファクタリング計画 `foundation-redesign-plan.md` は
`git show backup/foundation-bigbang-broken-bc1070e:docs/foundation-redesign-plan.md` で参照。

## ドキュメント管理ルール（崩壊防止の憲法）

1. **役割ごとに正本は1つ**。同じ役割の新ドキュメントを作るなら、古い方を必ず `old/` へ移す
   （「増やすなら畳む」）。
2. **新規ドキュメントはこの索引への登録とセット**。登録なしの新規作成は禁止。
3. **完了・失敗・方針転換したドキュメントは放置しない**: 冒頭に ARCHIVED ヘッダ
   （日付＋後継へのリンク＋現状と食い違う点）を付けて `old/` へ移し、この索引の表を更新する。
4. **生きているドキュメントから `old/` を参照しない**（経緯として言及する場合のみ可。
   手順・仕様の根拠として参照するのは禁止）。
5. **各正本は冒頭に「最終更新日＋ステータス」を必ず持つ**。大きな決定をしたら
   該当する正本を**同じコミットで**更新する（ドキュメントだけ後回しにしない）。
6. 状況メモ・引き継ぎメモを新規ファイルとして作らない。進捗・決定は
   foundation-rebuild-plan.md（開発）または universal-io-master-plan.md（製品）に追記する。
