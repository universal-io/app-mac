// User-visible recovery notices returned by every AI route. A fallback must
// never look like an ordinary clean success.
export type OperationalNotice = {
  severity: "warning";
  code: "MODEL_FALLBACK";
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

function displayRoute(vendor: string, modelId: string): string {
  return `${vendor} / ${modelId}`;
}
