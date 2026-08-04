// Reads a provider's `text/event-stream` body into parsed data payloads.

/**
 * Yields the JSON on each `data:` line of an SSE body.
 *
 * The `event:` name is deliberately ignored: every provider we stream from
 * repeats the event name inside the payload as `type`, and reading it from one
 * place means a payload cannot disagree with its own envelope.
 *
 * `[DONE]` terminates the stream — the Chat Completions convention, harmless
 * on the Responses API which does not send it.
 */
export async function* sseData(
  body: ReadableStream<Uint8Array> | null,
  label: string,
): AsyncGenerator<Record<string, unknown>> {
  if (!body) throw new Error(`${label} returned no response body.`);
  const reader = body.getReader();
  // A multi-byte character can straddle a network chunk; a non-streaming
  // decode would turn the halves into replacement characters.
  const decoder = new TextDecoder("utf-8");
  let buffer = "";

  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      // Events are separated by a blank line; a lone trailing chunk of a
      // partial event stays in the buffer until its terminator arrives.
      let split = buffer.indexOf("\n\n");
      while (split >= 0) {
        const frame = buffer.slice(0, split);
        buffer = buffer.slice(split + 2);
        const payload = dataPayload(frame);
        if (payload === DONE) return;
        if (payload) yield payload;
        split = buffer.indexOf("\n\n");
      }
    }
    const tail = dataPayload(buffer);
    if (tail && tail !== DONE) yield tail;
  } finally {
    // Abandoning a stream without releasing it holds the connection open for
    // the rest of the function's lifetime.
    reader.releaseLock();
  }
}

const DONE = Symbol("sse-done");

function dataPayload(frame: string): Record<string, unknown> | typeof DONE | null {
  const lines = frame.split("\n");
  const data = lines
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart())
    .join("\n");
  if (!data) return null;
  if (data === "[DONE]") return DONE;
  try {
    const parsed = JSON.parse(data);
    return typeof parsed === "object" && parsed !== null
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    // A frame we cannot read is not worth failing the whole answer over; the
    // events that carry the result are parsed or the stream ends without one.
    return null;
  }
}
