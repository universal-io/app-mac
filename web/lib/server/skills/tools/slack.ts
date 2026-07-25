import type { Skill } from "@/lib/server/skills/types";

export const SLACK_SKILL: Skill = {
  id: "slack",
  name: "Slack",
  layer: "tool",
  detect: (signals) =>
    signals.bundleId?.trim().toLowerCase() === "com.tinyspeck.slackmacgap"
    || matchesHost(signals.host, "app.slack.com")
    || matchesProduct(signals.appName, signals.windowTitle, "slack"),

  reading: `Slack-specific reading rules:
- The name and avatar attached to a message block identify its sender.
- A highlighted @mention inside a message identifies an addressee. An orange or yellow mention of the current user means the sender is addressing the user; it does not mean the user authored the message.
- The reply composer belongs to the current user. In a channel or thread, the lowest relevant human message nearest that composer is normally the newest.
- Files displayed inside or directly below a message belong to that message and its sender unless the screen clearly shows otherwise.
- Notices and controls such as "Only visible to you", mention warnings, Add Them, Let Them Know, and Dismiss are interface chrome, not human conversation turns.
- A timestamp far from the current time means the user is answering late; the sidebar shows other conversations, not this one.`,

  conventions: `How people write in Slack:
- Slack is short-form. Do not open with mail-style salutations or close with a signature block; a channel reply that reads like an email reads as misjudged.
- Match the register already visible in the channel. Teams that write casually stay casual even when the request is formal.
- Address the requester by name at the start only when the thread has several participants and it would otherwise be unclear who is being answered. In a direct message, or in a thread with one other person, naming them is redundant.
- Do not type an @ mention. The mention only becomes real when picked from Slack's autocomplete, and text pasted into the composer stays plain text — it notifies nobody and reads as a mistake. Write the person's name plainly if it is needed at all.
- When the reply is late relative to the message being answered, a brief acknowledgement of the delay is natural, but only when the relationship and channel tone support it. Never manufacture an excuse.
- Emoji and reactions carry real meaning here; a single trailing emoji is normal in casual channels and out of place in formal ones. Do not add one unless the visible tone already has them.`,

  affordances: `What Slack offers, when guidance is needed:
- Replying in a thread keeps a channel readable; replying in the channel surfaces it to everyone. "Also send to channel" does both.
- An emoji reaction acknowledges a message without adding a turn — often the right move for confirmations.
- Messages can be edited and deleted after sending, scheduled for later, saved for later, and turned into reminders.
- Files are shared by dragging into the composer or through the plus control next to it.
- Search covers messages and files; channel browsing and joining are separate from the sidebar list, which shows only joined channels.
- Huddles and calls start from a channel or DM header.`,

  attention: `States worth surfacing in Slack, at most one and only when certain:
- A bolded channel or DM in the sidebar is unread; a numeric badge is a direct mention or DM and matters more than plain unread.
- A workspace icon in the left rail carrying a badge means unread activity in a different workspace than the one on screen.
- A message addressed to the current user with no reply beneath it may be awaiting an answer.
- Draft indicators mean unsent text is waiting in another conversation.
Do not enumerate these. Most screens have unread markers, and reading them aloud every time is noise. Mention one only when it is both unambiguous and plausibly more urgent than what the user is already doing.`,

  facts: [
    { key: "account_name", label: "Slackでの表示名" },
    { key: "handle", label: "Slackのハンドル" },
    { key: "workspace", label: "主に使うワークスペース" },
  ],
};

/** Word-boundary match so "Slackline Inc" in a title does not count. */
export function matchesProduct(
  appName: string | undefined,
  windowTitle: string | undefined,
  productName: string,
): boolean {
  const identity = [appName, windowTitle].filter(Boolean).join(" ");
  const escaped = productName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|\\W)${escaped}(\\W|$)`, "i").test(identity);
}

/** Exact host, or a subdomain of it. Hosts are already lowercased and stripped
 * of "www." by the client. */
export function matchesHost(host: string | undefined, expected: string): boolean {
  const value = host?.trim().toLowerCase();
  if (!value) return false;
  return value === expected || value.endsWith(`.${expected}`);
}
