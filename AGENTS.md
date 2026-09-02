# Agent Rules (app-mac)

## 隣に複数のリポジトリがある（毎セッション必読）

`/Users/kaya.matsumoto/projects/universal-io/` の下に**独立した複数のgitリポジトリ**がある。

| パス | 中身 | `main` へのpushが意味すること |
|---|---|---|
| `app-mac`（ここ） | **macOSアプリのみ** | クライアントのソース更新（本番デプロイは起きない） |
| `api-gateway` | **本番Gateway＋認証＋課金＋Supabase** | **`api.universal-io.com` の本番デプロイ** |
| `web-product` | 製品サイト | `universal-io.com` の本番デプロイ |
| `app-ios` | iOSアプリ | — |
| `app-web` | Webクライアント（企画中） | — |

**2026-08-16にGatewayを`app-mac/web/`から`api-gateway`へ切り出した。**
このリポジトリに `web/` と `supabase/` はもう無い。APIの正本は `api-gateway/docs/api-contract.md`、
設計思想の正本は `api-gateway/docs/design-philosophy.md`。経緯は `app-web/docs/requirements.md`。

**エージェントのシェルは作業ごとに `app-mac` へ戻る。** `cd` した直後でも、次の
コマンドでは `app-mac` にいる。したがって裸の `git add -A && git commit` は、
どこで作業していたつもりでも `app-mac` にコミットされる。

実際に2026-08-02〜03のセッションで、`web-product` 向けのコミットが2回
`app-mac` に入り、そのたびに `README.md` の無関係な変更が別物のコミットメッセージで
記録された（どちらも `git reset --soft` で取り消し済み）。

規則:

- **gitは必ず `git -C <絶対パス>` を使う。** `cd` してから裸の `git` を打たない。
- npmも同様に `npm --prefix <絶対パス>`、またはそのコマンド内で `cd` を完結させる。
- コミット前に `git -C <パス> status --short` で、想定したファイルだけが載っているか確認する。
- 取り違えに気づいたら `git -C <誤ったパス> reset --soft HEAD~1` で戻し、
  巻き込んだファイルを `restore --staged` してから正しいリポジトリへ入れ直す。

## 🔑 アカウントと外部サービス（毎回忘れるので最初に読む）

**このプロダクトの外部設定は複数のGoogleアカウントに散っている。**
探し始める前にここを見ること。一度、OAuthクライアントを別アカウントのプロジェクトで
探し回って見つけられず、「Googleサインインは設定されていない」と誤って結論した。

| 何 | どこ | 備考 |
|---|---|---|
| **Google認証（OAuth）のGCP** | **`whatifepxyz@gmail.com`** | ここ以外のアカウントでは**プロジェクトの存在すら見えない**（`resourcemanager.projects.get` が403）。「無い」と誤認しやすい |
| ↳ プロジェクト番号 | `899703844772` | `https://console.cloud.google.com/auth/clients?project=899703844772` |
| ↳ OAuthクライアント名 | `Supabase Auth Client` | Client ID `899703844772-akc49a6icvjt6q7q44a9iqm6g80gjog4.apps.googleusercontent.com`（公開値） |
| ↳ OAuth同意画面 | 同じプロジェクト内 | ユーザーに見えるアプリ名はここ。別プロジェクトで整えても効果はない |
| **Gemini APIキー** | `matsumotokaya@gmail.com` の `My First Project`（番号 `118986914562`） | `universal-io` という名前だが**認証とは無関係**。Gateway の `GEMINI_API_KEY`。Google Cloud が「認証情報」に人の認証と機械の認証を並べているだけ |
| **Supabase** | organization `whatif-ep` / project `bomb-squad` | app-mac・api-gateway・app-web が**同一プロジェクトを共有**。だから同じアカウント・同じテナント・同じ利用枠になる |
| **顧客向け問い合わせ先** | **`info@universal-io.com`** | 届け先は `matsumotokaya@gmail.com` |

**Client ID の先頭の数字がGCPのプロジェクト番号。** 迷ったらこれで辿れる。

**Client Secret は Google 側で再表示できない。** Supabase に入っている値が唯一の在処で、
紛失したら新しいシークレットを追加してローテーションする。

**6か月使われないOAuthクライアントは削除対象**（Googleの通知あり、削除後30日は復元可）。

## 🔑 起動時に「キーチェーンへのアクセス」を何度も聞かれる時（毎回再発見していた）

**署名設定は正しい。** `project.yml`のDebugは安定した`Apple Development`＋`DEVELOPMENT_TEAM:
TG68TFXG88`で、そこにコメントで経緯も書いてある。**プロンプトの原因はそこではない。**

**原因は旧来型キーチェーンのACL。** macOSは項目ごとに「どのアプリが触れるか」をACLで持ち、それは
**項目を作ったアプリの署名**に紐づく。Supabase SDKは`kSecUseDataProtectionKeychain`を使わないので
（`Sources/Auth/Internal/Keychain.swift`で確認済み）、セッションは旧来型に入りACLの支配を受ける。
さらに**読み取りと書き込みでACLの許可が別**なので、1項目でも「起動時の読み」と「トークン更新の
書き込み」で2回聞かれる。

**2026-08-23に構造的な原因を1つ潰した。** サービス名が全configで`com.universal-io.mac.supabase`に
ハードコードされていたため、インストール済み本番アプリ（Developer ID署名）と開発ビルド
（Apple Development署名）が**同じ1項目を共有し、ACLの所有権を取り合っていた**。行き来するたびに
再発する。現在はbundle idから導出するので、本番は同じ文字列のまま（既存セッションは無傷）、
開発は`com.universal-io.mac.dev.supabase`を単独で持つ。

診断の順序:

1. `security dump-keychain 2>/dev/null | grep '"svce"'` で**項目を数える**（秘密は読まないので
   プロンプトは出ない）。現行の生きた項目は`com.universal-io.mac[.dev].supabase`の1件だけ。
   `com.universal-io.mac`と`com.heywatchme.bombsquad`の`*-api-key`はBYOK時代の残骸で、
   現行コードは読まない
2. `codesign -dvvv <app>` で**Authorityが`Apple Development`**であること、
   `TeamIdentifier=TG68TFXG88`を確認する。`adhoc`や署名なしなら毎ビルド必ず再発する
3. **CLI検証ビルド（`CODE_SIGNING_ALLOWED=NO`）で作った`.app`を起動しない。** あれは署名が無く、
   TCC許可もキーチェーンACLも成立しない。実機確認はXcodeから起動する

**「許可しない」を押しても壊れない**（未ログイン扱いになるだけ）。プロンプトは無限ではなく
「項目数×操作種別」で有限。

**それでも同一署名のビルド間で再発する場合**、残る手はデータ保護キーチェーンへの移行
（`kSecUseDataProtectionKeychain`）で、これは`keychain-access-groups`エンタイトルメントと
プロビジョニングプロファイルを要するため、リリース手順にも影響する別判断とする。

## Session Start Protocol（必読・毎セッション）

1. コードやドキュメントに触る前に **[docs/README.md](docs/README.md)（ドキュメント索引）を読む**。
   どのファイルが正本で、どれがアーカイブかはそこが唯一の答え。
2. 現行の製品・開発正本は [README.md](README.md) と
   [docs/universal-io-master-plan.md](docs/universal-io-master-plan.md)。
   作業の開始・完了・方針変更は**同じコミットで**該当する正本に反映する。
3. ドキュメント管理ルール（増やすなら畳む・索引登録必須・old/ 運用）は
   docs/README.md の「ドキュメント管理ルール」に従う。**新規 .md の無断作成は禁止**。

# Worktree Guard

This worktree is the active source of truth for the mainline and the upcoming
Copilot accuracy work.

Path:
- `/Users/kaya.matsumoto/projects/universal-io/app-mac`

Rules:
- Do code changes for the resumed mainline thread in this worktree.
- The stabilization worktree remains a recovery reference only:
  `/Users/kaya.matsumoto/projects/universal-io/app-mac-stabilize-foundation`
- If work intentionally moves away again in the future, update this file first.

Current branch:
- `fix/vision-bubble-placement-state`（R14バブルの1ターン1配置、AX miss時の本文表示順、印とカードの
  独立を実装し、2026-09-02に実機確認完了）。この修正自体に残タスクはない。復帰点は
  `pre-vision-bubble-placement-20260902`（`7804ad1`）。要件と経緯は
  `docs/universal-io-master-plan.md` R14と`docs/vision-bubble-placement-review.md`。

Current operational note:
- 2026-07-18: Vision/Copilotを単一の本番経路へ統合。旧Navigator、実験名、
  runtime flag、local Gateway、BYOK fallback、常設test/eval harnessは削除済み。
- 実験は短命ブランチで行い、終了時に本番ツリーへ残さない。

# Supabase Production Writes

- Bomb Squadの正しいMCPは `supabase_bomb_squad`、project refは
  `skcsbcyivjcvevxntvqa`。汎用名 `supabase` や他プロジェクトのMCPを使わない。
- schema/data readおよびSQL作業の前にproject URLを確認し、
  `https://skcsbcyivjcvevxntvqa.supabase.co` と完全一致しなければ停止する。
- 書き込み前にはURLを再確認し、migrationまたはSQLをレビューして、ユーザーの
  明示承認を得る。MCPがwrite-capableであること自体は実行承認ではない。
