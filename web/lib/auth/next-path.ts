// Post-login redirect guard. `/admin` (and other guarded pages) send
// unauthenticated users to `/auth?next=<path>`; after login we forward there.
// Only same-origin, absolute-path destinations are honored so the `next`
// parameter can't be turned into an open redirect to an external site.

export function safeInternalPath(value: string | null | undefined): string | null {
  if (!value) {
    return null;
  }
  // Must be an absolute in-app path...
  if (!value.startsWith("/")) {
    return null;
  }
  // ...but not a protocol-relative ("//host") or backslash-smuggled URL, which
  // browsers can resolve to a different origin.
  if (value.startsWith("//") || value.startsWith("/\\")) {
    return null;
  }
  return value;
}
