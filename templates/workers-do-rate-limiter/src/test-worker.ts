// Test-only Worker entry. The vitest suite needs a module that exports the
// Durable Object class, and this entry gives it one. Do not copy this file into
// a Worker; export `RateLimiter` from your own entry instead.
import { RateLimiter } from "./rate-limiter";

export { RateLimiter };

export default {
  async fetch(): Promise<Response> {
    return new Response("test worker only", { status: 404 });
  }
} satisfies ExportedHandler;
