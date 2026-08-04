// Pulls one string field out of a JSON object while it is still arriving.
//
// The models answer with a JSON object, not prose, so nothing can be shown
// until the object is complete — which is the whole wait. Under strict
// json_schema the keys arrive in schema order, and the deliverable field is
// placed near the front on purpose (see `JSON_INSTRUCTION` and
// `VISION_RESULT_SCHEMA_BASE`), so the sentence the user reads is generated
// before the bookkeeping fields. This turns that ordering into something the
// client can display as it comes.

/**
 * Feed it raw response text as it streams; it returns the newly decoded
 * characters of one string field, and nothing else.
 *
 * Escapes are decoded, so what comes out is display text rather than JSON
 * source. A chunk boundary landing inside an escape sequence holds the partial
 * sequence back rather than emitting `\` followed by `u30`.
 */
export class JSONStringFieldStream {
  private readonly opener: string;
  private buffer = "";
  private state: "seeking" | "reading" | "done" = "seeking";
  /**
   * A high surrogate whose partner has not been decoded yet. Emitting one on
   * its own would put an unpaired code unit on the wire, and a client that
   * decodes each increment as text — the macOS one does — turns that into a
   * replacement character. The emoji would be destroyed by where the chunk
   * boundary happened to fall.
   */
  private pendingHighSurrogate = "";

  /**
   * @param field key whose string value should be streamed. The scan assumes
   * no earlier value in the object can contain `"<field>":` — true for the
   * schemas here, where every field before the deliverable is a fixed enum.
   */
  constructor(field: string) {
    this.opener = `"${field}"`;
  }

  /** Whether the field's closing quote has been seen. */
  get finished(): boolean {
    return this.state === "done";
  }

  push(chunk: string): string {
    if (this.state === "done") return "";
    this.buffer += chunk;
    if (this.state === "seeking" && !this.locateValue()) return "";
    return this.readValue();
  }

  /**
   * Consumes everything up to and including the value's opening quote.
   * Returns false while the buffer has not reached it yet, keeping the bytes
   * for the next call.
   */
  private locateValue(): boolean {
    const keyAt = this.buffer.indexOf(this.opener);
    if (keyAt < 0) {
      // Keep only what could still be the start of the key across the split.
      const keep = this.opener.length - 1;
      if (this.buffer.length > keep) {
        this.buffer = this.buffer.slice(this.buffer.length - keep);
      }
      return false;
    }

    let cursor = keyAt + this.opener.length;
    while (cursor < this.buffer.length && /\s/.test(this.buffer[cursor])) cursor++;
    if (cursor >= this.buffer.length) return false;
    if (this.buffer[cursor] !== ":") {
      // A key-shaped run that was not this key. Step past it and look again.
      this.buffer = this.buffer.slice(keyAt + this.opener.length);
      return this.locateValue();
    }
    cursor++;
    while (cursor < this.buffer.length && /\s/.test(this.buffer[cursor])) cursor++;
    if (cursor >= this.buffer.length) return false;
    if (this.buffer[cursor] !== '"') {
      // The field is not a string here (null, a number, an object). Nothing to
      // stream, and pretending otherwise would emit garbage.
      this.state = "done";
      return false;
    }

    this.buffer = this.buffer.slice(cursor + 1);
    this.state = "reading";
    return true;
  }

  /** Decodes as much of the value as is unambiguously complete. */
  private readValue(): string {
    let out = this.pendingHighSurrogate;
    this.pendingHighSurrogate = "";
    let index = 0;

    while (index < this.buffer.length) {
      const char = this.buffer[index];

      if (char === '"') {
        this.state = "done";
        this.buffer = "";
        // Nothing more is coming, so a still-unpaired surrogate is simply
        // malformed input. Pass it on rather than silently dropping content.
        return out;
      }

      if (char !== "\\") {
        out += char;
        index++;
        continue;
      }

      // An escape needs its payload before it can be decoded. If the chunk
      // ended inside one, stop here and resume when the rest arrives.
      if (index + 1 >= this.buffer.length) break;
      const escape = this.buffer[index + 1];
      if (escape === "u") {
        if (index + 6 > this.buffer.length) break;
        const hex = this.buffer.slice(index + 2, index + 6);
        if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
          // Not a valid escape; pass it through rather than losing characters.
          out += char;
          index++;
          continue;
        }
        out += String.fromCharCode(parseInt(hex, 16));
        index += 6;
        continue;
      }
      out += SIMPLE_ESCAPES[escape] ?? escape;
      index += 2;
    }

    this.buffer = this.buffer.slice(index);
    return this.withoutTrailingHighSurrogate(out);
  }

  /** Splits off an unpaired trailing high surrogate to wait for its partner. */
  private withoutTrailingHighSurrogate(out: string): string {
    if (out.length === 0) return out;
    const last = out.charCodeAt(out.length - 1);
    if (last < 0xd800 || last > 0xdbff) return out;
    this.pendingHighSurrogate = out.slice(-1);
    return out.slice(0, -1);
  }
}

const SIMPLE_ESCAPES: Record<string, string> = {
  n: "\n",
  t: "\t",
  r: "\r",
  b: "\b",
  f: "\f",
  '"': '"',
  "\\": "\\",
  "/": "/",
};
