// These operational notices are developer-facing diagnostics. Owner decision
// 2026-07-15: they must be hidden or gated behind a developer setting before
// public release; end users must never see them.
export type OperationalNotice = {
  severity: "warning";
  code:
    | "MODEL_FALLBACK"
    | "PROVIDER_RETRY";
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

export function providerRetryNotice(vendor: string, modelId: string): OperationalNotice {
  return {
    severity: "warning",
    code: "PROVIDER_RETRY",
    message:
      `${displayRoute(vendor, modelId)} で一時的なエラーが発生しましたが、` +
      "再試行して処理を完了しました。",
  };
}

function displayRoute(vendor: string, modelId: string): string {
  return `${vendor} / ${modelId}`;
}
