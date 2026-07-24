export type SuggestApplicationIdentity = {
  appName?: string;
  bundleId?: string;
  windowTitle?: string;
};

export type SuggestContextAttachment = {
  id: string;
  name: string;
  instructions: string;
};

type SuggestContextPackage = SuggestContextAttachment & {
  matches: (identity: SuggestApplicationIdentity) => boolean;
};

const SLACK_PACKAGE: SuggestContextPackage = {
  id: "slack",
  name: "Slack",
  matches: ({ appName, bundleId, windowTitle }) =>
    bundleId?.trim().toLowerCase() === "com.tinyspeck.slackmacgap"
    || containsProductName(appName, windowTitle, "slack"),
  instructions: `Slack-specific reading rules:
- The name and avatar attached to a message block identify its sender.
- A highlighted @mention inside a message identifies an addressee. An orange or yellow mention of the current user means the sender is addressing the user; it does not mean the user authored the message.
- The reply composer belongs to the current user. In a channel or thread, the lowest relevant human message nearest that composer is normally the newest.
- Files displayed inside or directly below a message belong to that message and its sender unless the screen clearly shows otherwise.
- Notices and controls such as "Only visible to you", mention warnings, Add Them, Let Them Know, and Dismiss are interface chrome, not human conversation turns.`,
};

const GMAIL_PACKAGE: SuggestContextPackage = {
  id: "gmail",
  name: "Gmail",
  matches: ({ appName, windowTitle }) =>
    containsProductName(appName, windowTitle, "gmail"),
  instructions: `Gmail-specific reading rules:
- In an expanded message header, From identifies the sender and To identifies the addressee. A reply composer belongs to the current user.
- The newest expanded message nearest the reply composer is normally the message being answered; quoted or collapsed earlier mail is context, not the newest turn.
- Attachments shown within a message belong to that message's sender unless the screen clearly shows otherwise.
- Draft from the current user's perspective and do not claim that the user sent, created, or attached something shown in the incoming message.`,
};

// Package order is intentional: the first matching product supplies the
// attachment. Add products as separate packages instead of broad vendor rules
// such as "Google", because Gmail, Docs, and Sheets use different UI semantics.
const DEFAULT_CONTEXT_PACKAGES: readonly SuggestContextPackage[] = [
  SLACK_PACKAGE,
  GMAIL_PACKAGE,
];

export function resolveSuggestContextAttachment(
  identity: SuggestApplicationIdentity | undefined,
): SuggestContextAttachment | null {
  if (!identity) return null;
  const matched = DEFAULT_CONTEXT_PACKAGES.find((item) => item.matches(identity));
  if (!matched) return null;
  return {
    id: matched.id,
    name: matched.name,
    instructions: matched.instructions,
  };
}

function containsProductName(
  appName: string | undefined,
  windowTitle: string | undefined,
  productName: string,
): boolean {
  const identity = [appName, windowTitle].filter(Boolean).join(" ");
  const escapedName = productName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|\\W)${escapedName}(\\W|$)`, "i").test(identity);
}
