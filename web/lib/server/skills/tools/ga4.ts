import { matchesHost, matchesProduct } from "@/lib/server/skills/tools/slack";
import type { Skill } from "@/lib/server/skills/types";

// The first skill for a tool nobody writes messages in. Slack and Gmail are
// correspondence: heavy conventions, light affordances. Analytics is the
// reverse, and this file deliberately carries no conventions section at all —
// the drafting path then receives reading alone, which is the section split
// doing its job rather than a gap to fill.
//
// What this skill is for is the question a person actually has in front of a
// report: which number am I looking at, why does it disagree with the other
// one, and where is the control that changes it.
export const GA4_SKILL: Skill = {
  id: "ga4",
  name: "Google アナリティクス",
  layer: "tool",
  // One host serves every property; the account and property live inside the
  // page, never in the URL we read.
  detect: (signals) =>
    matchesHost(signals.host, "analytics.google.com")
    || matchesProduct(signals.appName, signals.windowTitle, "google analytics"),

  reading: `Google アナリティクス (GA4) specific reading rules:
- This screen is a measurement tool, not a conversation. There is no sender and no addressee, and normally nothing to reply to. Read it as a question about numbers.
- The left navigation splits the product: ホーム / Home, レポート / Reports (fixed reports), 広告 / Advertising (attribution), 探索 / Explore (free-form analysis), 管理 / Admin (configuration). Which of these the user is in decides what is even possible on screen.
- The property selector at the top names the account and the property being viewed. A GA4 property is not the same thing as the site or app it measures, and one account holds many properties — reading a number without knowing which property it came from is the most common way to be wrong here.
- Every number on screen is scoped by the date range control at the top right, plus any comparison chips and filters that are active. Two people reading "the same" metric are usually reading two different date ranges.
- Metric scope matters more than metric name. ユーザー / users, セッション / sessions, and イベント / events count different things, and the same word can be user-scoped in one report and session-scoped in another. ユーザー獲得 / User acquisition attributes to how a user was FIRST acquired; トラフィック獲得 / Traffic acquisition attributes each session. They are supposed to disagree.
- In 探索 / Explore the left 変数 / Variables panel holds the available dimensions, metrics, and segments, and the 設定 / Settings panel next to it is where they are placed into rows, columns, values, and filters. Nothing appears in the table until it has been placed there.
- リアルタイム / Realtime covers roughly the last 30 minutes only, and is not a small version of the other reports.
- "(not set)" is a real value meaning the dimension was not collected for those rows. It is data about collection, not about users.`,

  affordances: `What Google アナリティクス offers, when guidance is needed:
- レポート / Reports answer predefined questions. When the question does not fit one, 探索 / Explore is the answer: 自由形式 (free-form table), ファネルデータ探索 (funnel), 経路データ探索 (path). Sending someone to build an exploration is often the correct move rather than hunting for a report that does not exist.
- A report table takes a secondary dimension, and the search box above it filters rows. Both are faster than switching reports.
- 比較 / Comparisons at the top put segments of traffic side by side inside an ordinary report, without going to Explore.
- The date range control includes comparison to a previous period; period-over-period is a control, not a calculation to do by hand.
- Reports can be customised and saved into the ライブラリ / Library by users with edit rights; explorations are saved per user and shared explicitly.
- Data leaves through 共有 / Share and export — file download, Google スプレッドシート, Looker Studio, or the BigQuery export configured in 管理.
- 管理 / Admin owns everything configuration: data streams, events, conversions (key events), audiences, data retention, filters, and DebugView. If the question is "why is this not being measured", the answer is in 管理, not in the report.
- A GA4 property is separate from any Universal Analytics property. Historical UA data does not live here.`,

  attention: `States worth surfacing in Google アナリティクス, at most one and only when certain:
- A threshold notice (しきい値の適用 / data thresholding) means rows are being withheld, so totals and the visible rows do not reconcile. This silently changes what the screen says.
- A sampling indicator in an exploration means the numbers are estimates from a subset.
- Today and yesterday are incomplete: GA4 processing lags, so a recent-looking dip is often processing, not behaviour.
- A comparison or filter left active from earlier explains a number that looks wrong more often than the data does.
- A property that is newly created, or a date range predating the property's data collection, produces empty reports that are not a failure.
Do not enumerate these. Mention one only when it is unambiguous and actually changes how the number on screen should be read.`,

  facts: [
    { key: "account_name", label: "アナリティクスのアカウント名" },
    { key: "property_name", label: "主に見るプロパティ" },
  ],
};
