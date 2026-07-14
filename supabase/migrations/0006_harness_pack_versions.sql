begin;

-- Capability Packs are executable contracts in Navigator v4, so a tool ID
-- alone is not enough. Keep immutable versions for traces/runs while allowing
-- exactly one enabled global/tenant version at a time.
alter table public.bs_harness_packs
    add column if not exists pack_version text not null default 'unversioned-v3';

alter table public.bs_harness_packs
    drop constraint if exists bs_harness_packs_pack_version_nonempty;
alter table public.bs_harness_packs
    add constraint bs_harness_packs_pack_version_nonempty
    check (length(trim(pack_version)) > 0);

drop index if exists public.bs_harness_packs_global_tool_key;
drop index if exists public.bs_harness_packs_tenant_tool_key;

create unique index bs_harness_packs_global_tool_version_key
    on public.bs_harness_packs (tool_id, pack_version)
    where scope = 'global';

create unique index bs_harness_packs_tenant_tool_version_key
    on public.bs_harness_packs (tool_id, tenant_id, pack_version)
    where scope = 'tenant';

create unique index bs_harness_packs_one_active_global_tool_key
    on public.bs_harness_packs (tool_id)
    where scope = 'global' and enabled = true;

create unique index bs_harness_packs_one_active_tenant_tool_key
    on public.bs_harness_packs (tool_id, tenant_id)
    where scope = 'tenant' and enabled = true;

-- First typed vertical slice. The JSON stays aligned with the built-in GA4
-- fallback in web/lib/server/harness.ts. Only this route carries completion
-- evidence in v1; the remaining recipes are versioned but intentionally have
-- empty postconditions until their fixtures are added.
insert into public.bs_harness_packs (
    tool_id, pack_version, scope, tenant_id, match_hints, ui_map, recipes,
    prompt, min_plan, enabled
)
values (
    'ga4',
    '1',
    'global',
    null,
    '{"contains":["analytics.google.com","google analytics","google アナリティクス","アナリティクス"]}'::jsonb,
    $ui$レポート配下では、国・地域・言語・年齢・性別は「ユーザー属性」、デバイス・OS・ブラウザは「テクノロジー」、流入元は「集客」、ページ別閲覧は「エンゲージメント」に属する。「概要」は複数セクションにあるため親セクションを必ず区別する。$ui$,
    '[]'::jsonb,
    $prompt$この画面はGoogle Analytics 4（GA4）の可能性が高い。PackのUI mapとrecipeを正とし、実画面と食い違う場合は画面を優先して明示する。国・地域を見る要求をテクノロジーへ案内してはならない。$prompt$,
    'standard',
    true
)
on conflict do nothing;

update public.bs_harness_packs
set
    pack_version = '1',
    recipes = $recipes$[
      {
        "id": "page-metrics",
        "goal": "特定ページの指標（表示回数・セッション・ユーザー数など）を見る",
        "steps": [
          {"verbal":"左端のナビで「レポート」を開く","target":"レポート"},
          {"verbal":"左メニューの「エンゲージメント」を開く","target":"エンゲージメント"},
          {"verbal":"「ページとスクリーン」を開く","target":"ページとスクリーン"},
          {"verbal":"表の上の検索欄にページパスを入力して絞り込む","target":"検索","fill":"{ページパス}"},
          {"verbal":"右上の期間セレクタで対象期間（先月・過去30日など）を選ぶ"},
          {"verbal":"絞り込んだ行から対象の指標を読み取る"}
        ]
      },
      {
        "id": "bounce-rate",
        "goal": "直帰率を見る（既定レポートには無い指標）",
        "steps": [
          {"verbal":"左端のナビで「レポート」を開く","target":"レポート"},
          {"verbal":"左メニューの「エンゲージメント」を開く","target":"エンゲージメント"},
          {"verbal":"「ページとスクリーン」を開く","target":"ページとスクリーン"},
          {"verbal":"右上の鉛筆アイコン（レポートをカスタマイズ）を開く。見えない場合は編集者権限が無いので、探索で直帰率の表を組むか、目安として 100%−エンゲージメント率 を使う","target":"レポートをカスタマイズ"},
          {"verbal":"「指標」を開いて「直帰率」を追加し、適用する","target":"指標"},
          {"verbal":"表に追加された「直帰率」列を読み取る"}
        ]
      },
      {
        "id": "traffic-acquisition",
        "goal": "流入元（チャネル別のセッション数）を見る",
        "steps": [
          {"verbal":"左端のナビで「レポート」を開く","target":"レポート"},
          {"verbal":"左メニューの「集客」を開く","target":"集客"},
          {"verbal":"「トラフィック獲得」を開く","target":"トラフィック獲得"},
          {"verbal":"「セッションのデフォルトチャネルグループ」別の表から読み取る"}
        ]
      },
      {
        "id": "demographics",
        "goal": "訪問者の国・地域・言語を見る",
        "steps": [
          {
            "verbal":"左端のナビで「レポート」を開く",
            "target":"レポート",
            "postconditions":[{"kind":"candidate_present","selector":{"label":"ユーザー属性"}}]
          },
          {
            "verbal":"左メニューの「ユーザー属性」を開く",
            "target":"ユーザー属性",
            "postconditions":[{"kind":"candidate_present","selector":{"label":"ユーザー属性の詳細","parent_label":"ユーザー属性"}}]
          },
          {
            "verbal":"「ユーザー属性の詳細」を開く（国別の表が出る）",
            "target":"ユーザー属性の詳細",
            "postconditions":[
              {"kind":"environment_matches","url_contains":"/reports/demographics-details"},
              {"kind":"candidate_present","selector":{"label":"ユーザー属性の詳細","role":"heading"}},
              {"kind":"candidate_present","selector":{"label":"国"}}
            ]
          },
          {"verbal":"表のディメンション（列見出しのプルダウン）で「国」「地域」「市区町村」「言語」を切り替えて読み取る"}
        ]
      },
      {
        "id": "device-category",
        "goal": "デバイス別（モバイル/デスクトップ）の利用状況を見る",
        "steps": [
          {"verbal":"左端のナビで「レポート」を開く","target":"レポート"},
          {"verbal":"左メニューの「テクノロジー」を開く","target":"テクノロジー"},
          {"verbal":"「ユーザーの環境の詳細」を開く","target":"ユーザーの環境の詳細"},
          {"verbal":"表のディメンションを「デバイス カテゴリ」にして mobile / desktop / tablet の行を読み取る"}
        ]
      }
    ]$recipes$::jsonb,
    updated_at = now()
where tool_id = 'ga4' and scope = 'global';

comment on column public.bs_harness_packs.pack_version is
    'Immutable Capability Pack version pinned into Navigator Run and usage trace.';

commit;
