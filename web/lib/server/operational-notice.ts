// These operational notices are developer-facing diagnostics. Owner decision
// 2026-07-15: they must be hidden or gated behind a developer setting before
// public release; end users must never see them.
export type OperationalNotice = {
  severity: "warning";
  code:
    | "MODEL_FALLBACK"
    | "ROLE_DEGRADED"
    | "PROVIDER_RETRY"
    | "DATA_FALLBACK"
    | "STATE_FALLBACK"
    | "RUN_SNAPSHOT_MISSING";
  message: string;
};

export function modelFallbackNotice(args: {
  fromVendor: string;
  fromModelId: string;
  toVendor: string;
  toModelId: string;
}): OperationalNotice {
  return {
    severity: "warning",
    code: "MODEL_FALLBACK",
    message:
      `${displayRoute(args.fromVendor, args.fromModelId)} にアクセスできなかったため、` +
      `${displayRoute(args.toVendor, args.toModelId)} で処理しました。`,
  };
}

export function roleDegradedNotice(role: string, reason?: string): OperationalNotice {
  return {
    severity: "warning",
    code: "ROLE_DEGRADED",
    message:
      `${role}の処理に失敗したため、その補助機能なしで結果を表示しています。` +
      (reason ? ` 理由: ${reason}` : ""),
  };
}

export function providerRetryNotice(vendor: string, modelId: string): OperationalNotice {
  return {
    severity: "warning",
    code: "PROVIDER_RETRY",
    message:
      `${displayRoute(vendor, modelId)} で一時的なエラーが発生しましたが、` +
      "再試行して処理を完了しました。",
  };
}

export function dataFallbackNotice(component: string, fallback: string): OperationalNotice {
  return {
    severity: "warning",
    code: "DATA_FALLBACK",
    message: `${component}を読み込めなかったため、${fallback}を使用しています。`,
  };
}

export function stateFallbackNotice(
  component: string,
  fallback: string,
  reason?: string,
): OperationalNotice {
  return {
    severity: "warning",
    code: "STATE_FALLBACK",
    message:
      `${component}を開始できなかったため、${fallback}で案内しています。` +
      (reason ? ` 理由: ${reason}` : ""),
  };
}

/** The client sent a Copilot turn without the v4 Run snapshot, so the
 * shadow Verifier/Grounder/Renderer roles could not run this turn. */
export function runSnapshotMissingNotice(): OperationalNotice {
  return {
    severity: "warning",
    code: "RUN_SNAPSHOT_MISSING",
    message:
      "ナビゲーション状態のスナップショットを受信できなかったため、新しい検証機能をスキップしました。",
  };
}

function displayRoute(vendor: string, modelId: string): string {
  return `${vendor} / ${modelId}`;
}
