import { matchesHost, matchesProduct } from "@/lib/server/skills/tools/slack";
import type { Skill } from "@/lib/server/skills/types";

// Gmail, Docs, and Sheets are separate skills even though one vendor ships all
// three: their screens mean different things, and a "Google" skill would inject
// spreadsheet rules into a mail reply. Split by product, never by vendor.
export const GMAIL_SKILL: Skill = {
  id: "gmail",
  name: "Gmail",
  layer: "tool",
  // Host first. A Workspace tab reads "<subject> - <address> - <Org> Mail" and
  // contains no product name, so title matching alone finds only consumer
  // @gmail.com accounts — that is, everyone except the customers.
  detect: (signals) =>
    matchesHost(signals.host, "mail.google.com")
    || matchesProduct(signals.appName, signals.windowTitle, "gmail"),

  reading: `Gmail-specific reading rules:
- In an expanded message header, From identifies the sender and To identifies the addressee. A reply composer belongs to the current user.
- The newest expanded message nearest the reply composer is normally the message being answered; quoted or collapsed earlier mail is context, not the newest turn.
- A collapsed strip such as "… 3 more" hides earlier turns of the same thread. Their absence is not evidence that they do not exist.
- Attachments shown within a message belong to that message's sender unless the screen clearly shows otherwise.
- Labels, categories, and promotional banners are interface chrome, not part of the correspondence.`,

  conventions: `How people write in Gmail:
- Mail is long-form relative to chat. A salutation and a closing are expected, and their formality follows the incoming message.
- In Japanese business mail, the opening (お世話になっております等) and the closing (よろしくお願いいたします等) are near-obligatory; omitting them reads as brusque. Match the honorific level the sender used rather than defaulting to maximum politeness.
- Reply to the points raised, in the order raised. Mail readers expect a request to be answered item by item, unlike chat where a single line often suffices.
- Do not restate the entire incoming message. Quote only if the thread convention already quotes.
- Company signatures are appended by the client. Do not write one into the body.`,

  affordances: `What Gmail offers, when guidance is needed:
- Reply answers the sender; Reply all includes every recipient; Forward sends the thread onward to someone new. Choosing among these is frequently the actual decision.
- Sending can be scheduled, and a message can be unsent within the configured window right after sending.
- Threads can be archived, snoozed to return later, labelled, filtered, and muted.
- Attachments are added from the composer toolbar; large files route through Drive instead.
- Search supports operators such as from:, has:attachment, and before:/after:.`,

  attention: `States worth surfacing in Gmail, at most one and only when certain:
- An unread count on Inbox, or a thread awaiting a reply that the user opened without answering.
- A message that asks for something with a stated deadline visible on screen.
- A draft saved in the thread, meaning unsent text already exists.
- An attachment referenced in the text but absent from the message.
Do not enumerate these. Mention one only when it is unambiguous and plausibly more urgent than what the user is already doing.`,

  facts: ["address", "signature_name", "org_domain"],
};
