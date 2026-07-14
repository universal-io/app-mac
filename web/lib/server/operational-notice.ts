export type OperationalNotice = {
  severity: "warning";
  code: "MODEL_FALLBACK" | "ROLE_DEGRADED" | "PROVIDER_RETRY" | "DATA_FALLBACK";
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

export function roleDegradedNotice(role: string): OperationalNotice {
  return {
    severity: "warning",
    code: "ROLE_DEGRADED",
    message: `${role}の処理に失敗したため、その補助機能なしで結果を表示しています。`,
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

function displayRoute(vendor: string, modelId: string): string {
  return `${vendor} / ${modelId}`;
}
