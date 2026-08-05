import assert from "node:assert/strict";
import test from "node:test";

import {
  authContextCacheKey,
  jwtIdentityFromClaims,
} from "./jwt-identity.ts";

test("verified claims expose only the identity needed by AI authorization", () => {
  assert.deepEqual(
    jwtIdentityFromClaims({ sub: "user-id", email: "user@example.com" }),
    { userId: "user-id", email: "user@example.com" },
  );
});

test("email is optional but subject is mandatory", () => {
  assert.deepEqual(jwtIdentityFromClaims({ sub: "anonymous-user" }), {
    userId: "anonymous-user",
    email: null,
  });
  assert.equal(jwtIdentityFromClaims({ email: "user@example.com" }), null);
  assert.equal(jwtIdentityFromClaims({ sub: "" }), null);
  assert.equal(jwtIdentityFromClaims(null), null);
});

test("local AI verification cannot populate the sensitive Auth-server cache", () => {
  const digest = "same-access-token";
  assert.notEqual(
    authContextCacheKey(digest, "local-jwt"),
    authContextCacheKey(digest, "auth-server"),
  );
});
