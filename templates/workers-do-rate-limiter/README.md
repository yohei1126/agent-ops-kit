# Durable Object fixed-window rate limiter

Use this template when a Worker needs an exact per-key request limit. It ships
a small SQLite-backed Durable Object that counts calls in a fixed window and
tells the caller whether to allow the call and how long a blocked client should
wait. One object per caller key keeps the read, compare, and write in one
synchronous section, so two concurrent calls cannot both pass at the limit.

## What this template ships

| File | Purpose |
| --- | --- |
| [`src/rate-limiter.ts`](src/rate-limiter.ts) | `RateLimiter` Durable Object with `hit(limit, windowMs, now?)` |
| [`src/check.ts`](src/check.ts) | Optional `limitKey` helper for one namespace call |
| [`src/test-worker.ts`](src/test-worker.ts) | Test-only Worker entry, not for deploy |
| [`wrangler.snippet.jsonc`](wrangler.snippet.jsonc) | Binding and migration entries to copy |
| [`wrangler.jsonc`](wrangler.jsonc) | Test-only config for the vitest suite |
| [`test/rate-limiter.test.ts`](test/rate-limiter.test.ts) | Workers vitest suite |

The class imports no project `Env`, route table, audit helper, or secret type.
Storage holds the window bounds and the count only. The caller key lives in the
object name and never reaches SQL or logs.

## The Workers Rate Limiting pitfall

The Workers Rate Limiting binding is easy to deploy and easy to trust. In one
private job-hub Worker the binding was present and `limit()` resolved
`{ success: true }` on every call. The operator sent 120 sequential
`GET /health` requests from one client IP in about 57 seconds. Every request
returned 200 from one Cloudflare location, and none returned 429. `wrangler
tail` during the burst showed no limiter error and no blocked audit line.

A binding that reports success while it does not enforce is worse than no
binding, because the access log looks healthy. Treat the binding as a coarse
hint unless you have measured it on the route you care about.

## Detect an unenforced binding

The check needs one client, one route, and the documented limit and window:

1. Send more than the documented limit in sequence from one client inside one
   window. Keep the request count small enough that the run fits in the window.
2. Record each status code and the location from the `cf-ray` response header.
   The suffix after the last `-` is the location, such as `-SIN`.
3. Confirm that the responses share one location. A run spread across
   locations proves nothing about one limiter instance.
4. Expect a 429 at or before the documented limit. All 200 responses mean the
   limit was not enforced on that route.
5. Run `wrangler tail` during the burst. Compare limiter audit lines with the
   silent success path. A missing audit line on a call that should be blocked
   is another sign.

[`scripts/rate-limit-check.sh`](../../scripts/rate-limit-check.sh) automates the
request loop and the location summary. It sends no credentials, no cookies,
and no custom auth headers, and it never follows redirects. Run it against a
host you own:

```bash
scripts/rate-limit-check.sh --base-url https://example.com \
  --path /health --limit 100 --window 60 --mode detect
```

Detection mode fails when every response succeeds. Enforcement mode requires a
429 and a valid `Retry-After`.

## Why a Durable Object is the strict-limit path

A Durable Object handles one event at a time. The limiter reads its row,
compares the count with the limit, and writes the new count before it yields.
The runtime cannot interleave a second call inside that section. Storage is
SQLite in the object, so the counter survives eviction. An alarm clears the
table when the window ends, so an idle key keeps no data.

Cloudflare documents this split in the
[Rate Limiting binding strict limits](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/#strict-limits)
section. The binding suits coarse protection. A Durable Object suits an exact
limit. See the
[Durable Objects documentation](https://developers.cloudflare.com/durable-objects/)
for the platform model.

## Copy the template into a Worker

1. Copy `src/rate-limiter.ts` into your source tree. Copy `src/check.ts` too if
   the namespace helper is useful.
2. Export the class from your Worker entry:

   ```ts
   export { RateLimiter } from "./rate-limiter";
   ```

3. Add the binding and one migration from
   [`wrangler.snippet.jsonc`](wrangler.snippet.jsonc) to your `wrangler.jsonc`.
   The migration tag is a placeholder. Replace it with your next tag, append it
   after every migration already in the file, and never edit an applied
   migration.
4. Call the limiter before the route does its work:

   ```ts
   const clientIp = request.headers.get("cf-connecting-ip") ?? "unknown";
   const result = await limitKey(
     env.RATE_LIMITER,
     `${clientIp}:${group}`,
     limit,
     windowMs
   );
   if (!result.allowed) {
     return new Response("Too Many Requests", {
       status: 429,
       headers: { "Retry-After": String(result.retryAfterSeconds) }
     });
   }
   ```

5. Keep the route group in the key. `${clientIp}:${group}` gives each route
   family its own allowance and stops a webhook burst from blocking claim
   traffic.

### Choose the key

One object exists per key passed to `idFromName`. Pick a value that identifies
the caller and the protected action. A key can be an IP address, an account id,
an API token id, or a combination with a route group. A shared key shares one
counter, which is the right choice for a global cap and the wrong choice for
per-tenant caps.

### Return 429 with Retry-After

`hit` returns `retryAfterSeconds` for the current window, with a floor of one
second. Send it in the `Retry-After` header. Add `Cache-Control: no-store` on
the 429 so a cache does not replay the block.

### Choose your own fail policy

The template does not decide what happens when `hit` rejects. A public webhook
might fail closed with 503, while a health route might fail open and still log
the error. Pick one policy per route, write it at the call site, and keep the
error audit free of keys and IP addresses.

## Known limitations

- The key is the full client address. A single IPv6 host can present several
  addresses inside its `/64` prefix, and each one is a distinct key. Normalize
  an IPv6 address to its `/64` prefix in the caller if a host should share one
  bucket.
- A 429 is still a request that Cloudflare bills. The limiter protects a
  backend and the work behind it, not your request volume.
- One object per key has a cost in object count and wakeups. Group small or
  short-lived keys under one route-level key when exact per-key isolation is
  not required.

## Run the tests

The suite uses Workers vitest through `@cloudflare/vitest-plugin`. The kit
pins Node 22 in the repository root `.nvmrc` and in this package's
`engines.node`.

```bash
npm ci
npx --no-install tsc --noEmit
npx --no-install vitest run
```

The test config in [`wrangler.jsonc`](wrangler.jsonc) is for the suite only. It
binds `RATE_LIMITER` to the test worker and uses the `test-v1` migration tag.
Do not deploy it.

The tests use synthetic window-aligned `now` values. The alarm tests park and
run alarms through `runInDurableObject` and `runDurableObjectAlarm`, so they do
not wait for a real minute to pass.

## Related docs

- [Cloudflare Rate Limiting binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [Cloudflare Durable Objects](https://developers.cloudflare.com/durable-objects/)
- [Operator rate limit check](../../scripts/README.md#check-rate-limiting-on-one-url)
