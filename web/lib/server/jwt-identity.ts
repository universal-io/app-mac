export type JWTIdentity = {
  userId: string;
  email: string | null;
};

export type JWTVerificationMode = "auth-server" | "local-jwt";

/** Never let a locally verified AI context satisfy a sensitive getUser path. */
export function authContextCacheKey(
  tokenDigest: string,
  verification: JWTVerificationMode,
): string {
  return `${verification}:${tokenDigest}`;
}

/**
 * Claims are trusted only after Supabase has verified the token signature and
 * expiry. Keep extraction separate and deliberately small: authorization still
 * comes from the tenant and entitlement rows, never from customizable claims.
 */
export function jwtIdentityFromClaims(
  claims: { sub?: unknown; email?: unknown } | null | undefined,
): JWTIdentity | null {
  if (typeof claims?.sub !== "string" || claims.sub.length === 0) return null;
  return {
    userId: claims.sub,
    email: typeof claims.email === "string" ? claims.email : null,
  };
}
