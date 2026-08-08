import { matchesProduct } from "@/lib/server/skills/tools/slack";
import type { Skill } from "@/lib/server/skills/types";

// The first skill for a macOS system utility rather than a product someone
// signed up for, and the first one whose premise is that the user cannot read
// the screen at all. Slack and Gmail are legible to everyone who opens them;
// Activity Monitor is a table of process names most people have never seen,
// where the honest baseline is that nine rows in ten mean nothing. Getting a
// person from nothing to a workable reading of the screen is the entire value
// here, so this skill spends its length on how to read rows and what is normal,
// not on navigation.
//
// It carries no conventions section: nobody writes anything here.
//
// The hard boundary is evidence. Universal I/O never runs ps, top, or
// powermetrics — the screenshot is the only source, so a column the user has
// not shown is gone, and the correct move is to name the column rather than to
// estimate the number.
export const ACTIVITY_MONITOR_SKILL: Skill = {
  id: "activity-monitor",
  name: "アクティビティモニタ",
  layer: "tool",
  // A native app, so the bundle id is the process itself rather than a
  // browser's. The localized name differs per system language, hence both.
  detect: (signals) =>
    signals.bundleId?.trim().toLowerCase() === "com.apple.activitymonitor"
    || matchesProduct(signals.appName, signals.windowTitle, "activity monitor")
    || matchesProduct(signals.appName, signals.windowTitle, "アクティビティモニタ"),

  reading: `アクティビティモニタ / Activity Monitor specific reading rules:

Who is looking at this screen. Assume the process names mean nothing to them. Most rows here are macOS components and helper processes nobody chose to run, and the useful answer explains what a row IS and whether it is normal — not what the interface is called. Prefer plain language over precision: "Spotlightがファイルの索引を作っている最中で、これは一時的なもの" is worth more than an exact definition of the same daemon. Never answer by describing the tabs and columns as if giving a tour.

Naming an unfamiliar process. Say what you actually recognize. When a name is unfamiliar, read its shape instead of inventing a purpose: a trailing "d" means a background service (daemon) rather than an app, a name containing "Helper" is a child process of the app it names, a "com.apple.*" style name is an Apple system component, and a name in the ユーザー column of "root" or a "_"-prefixed account belongs to the system rather than to the person. Saying "これはmacOS自身のバックグラウンド処理です" with the naming evidence is correct; guessing a specific function for a name you do not know is not.

The tabs answer different questions and each one changes which numbers exist: CPU (計算), メモリ / Memory (占有), エネルギー / Energy (電池), ディスク / Disk (読み書き), ネットワーク / Network (通信). Which tab is selected decides what can be said at all.

%CPU is normalised per core: 100% means one core fully occupied, not the whole machine. A Mac with many cores can legitimately show 300% or 700% for one process, and a number above 100 is not an error. The システム / ユーザー / アイドル figures at the bottom describe the whole machine.

One app is normally many rows. Browsers and Electron apps run a separate process per tab, extension, and subsystem, so several rows with the same name are one program, and what matters is the family total rather than any single row. A second row is not a second copy of the app.

On the メモリ tab, the メモリプレッシャー graph at the bottom is the actual health indicator, not the numbers beside it. Green means the machine is coping even when スワップ使用領域 is non-zero; yellow means memory is being compressed and swapped to cope; red means there is genuinely not enough. キャッシュされたファイル is memory holding recently used file data and is released to apps on demand — it is memory being used well, not memory lost. The per-process メモリ column is that process's own footprint and the column does not sum to 使用済みメモリ, so do not add it up and reconcile.

On the エネルギー tab, エネルギー影響 is a relative score with no unit — never read it as watts. 平均エネルギー影響 covers roughly the last 8 hours (or since startup, if shorter), so it and the instantaneous column disagreeing is normal rather than a contradiction.

On the ディスク and ネットワーク tabs, the default byte columns are cumulative totals since each process started, not rates. A large number there often means the process has simply been running for weeks. The graph at the bottom is the rate; the columns are not.

"(応答なし)" beside a name, usually in red, means that app is not answering the window system. It is the one row state that is unambiguous.

Which processes are listed depends on the 表示 / View menu filter. A process the user expects and cannot find is usually filtered out rather than absent.

The screenshot is the only evidence. A column that is not displayed cannot be recovered, and neither can process history, parentage, or what a process is doing internally. When answering needs a number that is not on screen, say which column or tab would show it instead of estimating.`,

  affordances: `What アクティビティモニタ offers, when guidance is needed:
- Clicking a column header sorts by it, and clicking again reverses. This is the main tool on this screen: sorting メモリ or %CPU descending puts whatever is responsible in the top row.
- 表示 / View › 列 / Columns adds hidden columns. Many questions fail only because the needed column is not displayed — %CPU is not shown on the メモリ tab, and rate columns for disk and network are off by default.
- 表示 / View › すべてのプロセス shows system and other users' processes, and the 階層表示 / hierarchically variant groups helper processes under their parent app, which is what turns a dozen identical browser rows into one readable family.
- The search field filters the list by name, which is faster than hunting for a row.
- Selecting a process and pressing the ⓘ button opens 検査 / Inspect: memory detail, statistics, and open files and ports for that one process.
- サンプリング / Sample Process, from the same inspector or the 表示 menu, records what a stuck process is actually executing. This is the real tool for an app that has stopped responding.
- The ✕ button quits or force quits the selected process. Propose this only for an ordinary application owned by the user, and prefer quitting the app itself first. Never propose force quitting a system process or anything owned by root — macOS restarts most of them anyway, and the rest destabilise the session.
- 表示 › 更新頻度 changes how often the figures refresh; a number that will not sit still is often just a 5-second update interval.
- The ウインドウ / Window menu opens small floating CPU usage and CPU history panels that stay visible while working in other apps, and 表示 › Dockアイコン puts a live graph in the Dock.`,

  attention: `States worth surfacing in アクティビティモニタ, at most one and only when certain:
- One process holding a large share of the machine's 物理メモリ while nothing else comes close. This is the single most useful thing to point out here, because it is usually the reason the user opened this screen. State the process, the figure as shown, and whether that size is expected for that kind of program.
- One process sitting far above the others in %CPU while the machine is otherwise idle — particularly an app the user is not currently interacting with.
- メモリプレッシャー in yellow or red. Red is worth raising over almost anything else on this screen.
- An app marked (応答なし).
- kernel_task consuming heavy CPU is normal Apple behaviour under heat, not a fault: macOS occupies cores deliberately to reduce heat. Say so rather than treating it as a runaway. The same applies to mds / mdworker_shared (Spotlight indexing), backupd (Time Machine), and photoanalysisd — all are temporary background work that finishes on its own.
Raise one, in the user's terms, and do not enumerate the rest. A screen where nothing stands out should be said to look ordinary.`,
};
