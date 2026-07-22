// Memory-card LLM calls for the AI gateway: persona bootstrap (onboarding)
// and post-deploy distillation. Server-side port of the macOS MemoryDistiller
// and PersonaPrompt (BombSquad/Services/MemoryDistiller.swift,
// BombSquad/Resources/PersonaPrompt.swift); keep the Japanese prompt text in
// sync with the Swift originals.

import {
  apiKeyFor,
  endpointFor,
  ProviderCallError,
  runWithModelFallback,
  type AIModelTarget,
} from "@/lib/server/ai-routing";
import type { OperationalNotice } from "@/lib/server/operational-notice";
import type { SituationalContextPayload } from "@/lib/server/prompts";

export const BOOTSTRAP_SYSTEM = `あなたは文体プロファイラーです。ユーザーが過去に実際に送ったメッセージのサンプルを受け取り、
そのユーザーの「スタイルプロファイル」を Markdown で作成します。

このプロファイルは、AI がこのユーザーの代わりに文章を整えるとき
「本人が書いたと自然に感じられる文体」を再現するための参照資料です。

# 出力形式（この構成の Markdown だけを出力する。前後の説明文・コードブロック記号は不要）
# スタイルプロファイル

## 文体の基調
（丁寧/カジュアル、文の長さ、改行の癖など。サンプルから読み取れた事実だけ）

## 敬語・距離感
（敬語レベル、社内外での使い分けの兆候）

## 語彙・言い回しの癖
（よく使う表現、書き出し・結びのパターン）

## 記号・絵文字
（絵文字・顔文字・「！」等の使用傾向。使わないならそう書く）

## 署名・定型
（定型の挨拶や署名があれば）

## 避けるべき表現
（このユーザーが使わなそうな表現・トーン）

# ルール
- サンプルから読み取れることだけを書く。推測で人格を創作しない。
- 各項目は1〜3行の箇条書きで簡潔に。
- サンプルが少なく判断できない項目は「（サンプル不足）」と書く。
- メッセージの内容（固有名詞・案件・機密）はプロファイルに含めない。文体の特徴だけを抽出する。`;

export const DISTILL_SYSTEM = `あなたは文体学習の観察者です。1回の送信について、次の3つを受け取ります:
- original: ユーザーが最初に書いた下書き
- suggestion: AI が提案した修正文
- final: ユーザーが実際に送信した文（suggestion をそのまま、または編集したもの）
加えて、送信先アプリや会話の抜粋（周辺コンテクスト）が付くことがあります。

あなたの仕事は「ユーザーが AI の提案をどう直したか」から、確度の高い学びだけを抽出することです。
- suggestion と final の差分が最大の情報源。ユーザーが戻した表現・削った表現・足した表現に注目する。
- original の癖（絵文字、語尾、挨拶など）が final でも維持されていれば、それはユーザーの一貫した好み。

出力は次の JSON オブジェクト1つだけ（コードブロックや説明文を付けない）:
{
  "persona_note": "ユーザーの文体の好みとして新たに分かったこと1つ（30字程度・日本語）。確度の高い学びがなければ null",
  "relationship_subject": "会話の相手が特定できる場合その表示名。特定できなければ null",
  "relationship_note": "その相手とのやり取りで分かったこと1つ（敬語レベル・呼称・関係性。30字程度）。なければ null"
}

# ルール
- 確度が高い場合だけ出す。迷ったら null。毎回何かを出す必要はまったくない。
- メッセージの内容（案件・数値・機密）は書かない。文体・関係性の特徴だけ。
- relationship_subject はコンテクストに実際に現れた人名・チャンネル名だけ。創作しない。
- 1回の観察から断定的な一般化をしない（「常に」ではなく「〜する傾向」と書く）。`;

export type DistillObservation = {
  original: string;
  suggestion: string;
  final: string;
  context?: SituationalContextPayload;
};

export type DistillNotes = {
  persona_note: string | null;
  relationship_subject: string | null;
  relationship_note: string | null;
};

export type MemoryEngineOutput<T> = {
  result: T;
  modelVendor: string;
  modelId: string;
  modelApi: string;
  fallbackUsed: boolean;
  inputTokens: number;
  outputTokens: number;
  notices: OperationalNotice[];
};

export async function runPersonaBootstrap(
  samples: string,
): Promise<MemoryEngineOutput<{ persona_md: string }>> {
  const user = `以下はユーザーが過去に実際に送ったメッセージのサンプルです。スタイルプロファイルを作成してください。\n\n${samples}`;
  const routed = await routedChat(BOOTSTRAP_SYSTEM, user, false);
  const personaMd = routed.value.content.trim();
  if (!personaMd) throw new ProviderCallError("Provider returned an empty persona card.");
  return {
    result: { persona_md: personaMd },
    modelVendor: routed.modelVendor,
    modelId: routed.modelId,
    modelApi: routed.api,
    fallbackUsed: routed.fallbackUsed,
    inputTokens: routed.value.inputTokens,
    outputTokens: routed.value.outputTokens,
    notices: routed.notices,
  };
}

export async function runDistillation(
  observation: DistillObservation,
): Promise<MemoryEngineOutput<DistillNotes>> {
  const user = distillUser(observation);
  const routed = await routedChat(DISTILL_SYSTEM, user, true);

  const json = extractJSON(routed.value.content);
  if (!json) {
    throw new ProviderCallError("Provider response contained no JSON object.");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new ProviderCallError("Provider response JSON failed to parse.");
  }
  const root = parsed as Record<string, unknown>;
  return {
    result: {
      persona_note: nonEmptyString(root.persona_note),
      relationship_subject: nonEmptyString(root.relationship_subject),
      relationship_note: nonEmptyString(root.relationship_note),
    },
    modelVendor: routed.modelVendor,
    modelId: routed.modelId,
    modelApi: routed.api,
    fallbackUsed: routed.fallbackUsed,
    inputTokens: routed.value.inputTokens,
    outputTokens: routed.value.outputTokens,
    notices: routed.notices,
  };
}

function distillUser(observation: DistillObservation): string {
  const sections: string[] = [];
  const context = observation.context;
  if (context?.app_name) {
    let line = `送信先アプリ: ${context.app_name}`;
    if (context.window_title) {
      line += `（${context.window_title}）`;
    }
    sections.push(line);
    if (context.conversation_excerpt) {
      sections.push(`会話の抜粋:\n${context.conversation_excerpt.slice(-800)}`);
    }
  }
  sections.push(`original:\n${observation.original}`);
  sections.push(`suggestion:\n${observation.suggestion}`);
  sections.push(`final:\n${observation.final}`);
  return sections.join("\n\n");
}

function routedChat(
  system: string,
  user: string,
  jsonMode: boolean,
){
  return runWithModelFallback("memory", (target) =>
    chat(target, system, user, jsonMode)
  );
}

async function chat(
  target: AIModelTarget,
  system: string,
  user: string,
  jsonMode: boolean,
): Promise<{ content: string; inputTokens: number; outputTokens: number }> {
  if (target.api !== "chat_completions") {
    throw new ProviderCallError(`Memory cannot use API "${target.api}".`);
  }

  const body: Record<string, unknown> = {
    model: target.modelId,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
  };
  if (target.vendor === "openai") {
    body.max_completion_tokens = 2048;
    body.reasoning_effort = "none";
  } else {
    body.max_tokens = 2048;
    body.reasoning_effort = "low";
  }
  if (jsonMode) {
    body.response_format = { type: "json_object" };
  }

  const response = await fetch(endpointFor(target), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKeyFor(target)}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    throw new ProviderCallError(`Provider HTTP ${response.status}.`, {
      rateLimited: response.status === 429,
    });
  }

  const root = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
    usage?: { prompt_tokens?: number; completion_tokens?: number };
  };
  const content = root.choices?.[0]?.message?.content;
  if (!content) {
    throw new ProviderCallError("Provider returned no content.");
  }
  return {
    content,
    inputTokens: root.usage?.prompt_tokens ?? 0,
    outputTokens: root.usage?.completion_tokens ?? 0,
  };
}

function nonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed && trimmed.toLowerCase() !== "null" ? trimmed : null;
}

/** Tolerates reasoning blocks or stray prose around the JSON object. */
function extractJSON(raw: string): string | null {
  let text = raw;
  const thinkEnd = text.lastIndexOf("</think>");
  if (thinkEnd >= 0) {
    text = text.slice(thinkEnd + "</think>".length);
  }
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < start) return null;
  return text.slice(start, end + 1);
}
