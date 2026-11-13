import type { RateLimiter } from "../src/rate-limiter";

declare global {
  namespace Cloudflare {
    interface Env {
      RATE_LIMITER: DurableObjectNamespace<RateLimiter>;
    }
  }
}

export {};
