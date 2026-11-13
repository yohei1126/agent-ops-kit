import type { RateLimitResult, RateLimiter } from "./rate-limiter";

/**
 * Count one call for `key` through a `RateLimiter` namespace.
 *
 * The key identifies one bucket: one Durable Object per key, so a shared key
 * shares a counter. A typical key is `${clientIp}:${routeGroup}`, which keeps
 * each route group on its own allowance.
 *
 * The helper deliberately makes no fail-open or fail-closed decision. A
 * caller decides what to do when `hit` rejects or returns `allowed: false`.
 */
export function limitKey(
  namespace: DurableObjectNamespace<RateLimiter>,
  key: string,
  limit: number,
  windowMs: number,
  now?: number
): Promise<RateLimitResult> {
  const stub = namespace.get(namespace.idFromName(key));
  return stub.hit(limit, windowMs, now);
}
