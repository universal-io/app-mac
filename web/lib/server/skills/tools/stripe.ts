import { matchesHost, matchesProduct } from "@/lib/server/skills/tools/slack";
import type { Skill } from "@/lib/server/skills/types";

// Stripe's dashboard is where a mistake costs money rather than clarity, and
// the two mistakes that matter are structural, not navigational: building in
// one environment and looking for it in the other, and confusing a product
// with the price that actually gets charged. Both are invisible until much
// later, so they lead this skill.
//
// Labels move between dashboard versions and between Japanese and English, so
// this describes what a control does and where it sits rather than betting on
// its exact string.
export const STRIPE_SKILL: Skill = {
  id: "stripe",
  name: "Stripe",
  layer: "tool",
  detect: (signals) =>
    matchesHost(signals.host, "dashboard.stripe.com")
    || matchesProduct(signals.appName, signals.windowTitle, "stripe"),

  reading: `Stripe dashboard specific reading rules:
- Find the environment first. The dashboard runs in a test environment (テスト環境 / sandbox) or the live one (本番環境), switched near the top of the window and usually marked with a coloured banner or badge. The two hold completely separate data: a product created in test does not exist in live, and vice versa. Any answer about what exists on this account is wrong unless the environment is established.
- An account that has not completed activation can browse everything and charge nobody. Prompts to 本番環境を有効化 / activate, or to supply business details, mean live payments are not yet possible regardless of what has been built.
- 商品カタログ / Product catalog holds 商品 (products), and each product holds one or more 価格 (prices). The product is what you are selling; the price is the amount, currency, and interval that actually gets charged. A subscription is always attached to a recurring price, never to a product alone — so a product with no recurring price is not yet sellable as a subscription.
- Amounts are shown in the currency of the price being displayed. A price's currency and interval are fixed when it is created; a product can carry several prices to offer monthly and yearly, or two currencies.
- 顧客 (Customers), 取引 / 支払い (Payments), 請求書 (Invoices), and サブスクリプション (Subscriptions) are records, not settings. Changing what future customers get happens in the catalog and in 設定 (Settings), not on a past record.
- Secret keys, bank account numbers, and identity documents are values, not interface text. Never transcribe, repeat, or include them in any answer, even when they are plainly visible on screen. Describe where they are and what to do with them instead.`,

  affordances: `What the Stripe dashboard offers, when guidance is needed:
- Selling a subscription needs, in order: a product, a recurring price on that product, and a way for a customer to reach it. The third can be a 支払いリンク / Payment link (a hosted URL, no code), Stripe Checkout (a hosted page created from your backend), or Billing invoices. The payment link is the shortest route from nothing to a working subscription.
- 商品を追加 / Add product asks for a name, an optional description, then the pricing model: 継続 / recurring versus 一括 / one-off. Recurring asks for the interval (monthly, yearly), and optionally a free trial. Tiered and usage-based (metered) pricing are chosen here too, at creation.
- A price cannot be edited after creation — not the amount, not the currency, not the interval. Changing the price of something means creating a new price and archiving the old one; existing subscriptions keep the price they were created with unless they are explicitly migrated. Archiving hides a price from new purchases without touching existing subscribers.
- 顧客ポータル / Customer portal, configured under 設定 → 請求 / Billing, is how subscribers cancel, switch plans, and update cards without writing any of that UI. It must be configured before it can be linked to.
- Activating the account for live payments requires business details, a representative and identity verification, a bank account for payouts, and the public-facing information customers will see on statements and receipts. In Japan a site selling subscriptions is also expected to publish 特定商取引法に基づく表記. Review is not instant, so activation is worth starting before the catalog is finished, not after.
- 開発者 / Developers holds API keys, webhooks, and event logs. Subscriptions are driven by webhook events — checkout completed, subscription created or updated or deleted, invoice paid, invoice payment failed — and a subscription integration that reads none of these will not know when a customer stops paying.
- Test clocks let a subscription be advanced through renewals and failures without waiting for real time to pass.`,

  attention: `States worth surfacing on a Stripe screen, at most one and only when certain:
- The environment is not the one the user's task implies — building a catalogue in test when they are trying to launch, or editing live data while believing it is test. This is the most consequential mismatch on this product.
- The account is not activated, while the task on screen only pays off in live mode.
- A product exists with no recurring price, or with a one-off price, while the goal is a subscription.
- A screen showing a secret key, bank account, or identity document. Say that the screen contains credentials and stop there; do not read the values.
- A price is about to be changed on something customers already subscribe to, which is not what the edit will do.
Do not enumerate these. Mention one only when it is unambiguous and changes what the user should do next.`,

  facts: [
    { key: "business_name", label: "Stripeの事業者名" },
    { key: "default_currency", label: "主に使う通貨" },
  ],
};
