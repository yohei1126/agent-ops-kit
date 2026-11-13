import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { limitKey } from "../src/check";
import type { RateLimiter } from "../src/rate-limiter";

/**
 * Window length used by every test. The production window is the caller's
 * choice; 60 s keeps the arithmetic readable.
 */
const WINDOW_MS = 60_000;

/** Start of the window `offset` windows from the real one, aligned. */
function alignedWindow(offset: number): number {
  return (Math.floor(Date.now() / WINDOW_MS) + offset) * WINDOW_MS;
}

/**
 * A synthetic base window far in the future, so the alarm every hit schedules
 * stays pending instead of firing while the test runs. A test that depends on
 * the window passes `WINDOW_START` plus an explicit offset as `now`, so the
 * real clock never decides which window it lands in.
 */
const WINDOW_START = alignedWindow(1000);

let keySeq = 0;

/** A fresh key per test, so no two tests share a counter. */
function nextKey(label: string): string {
  keySeq += 1;
  return `test-${label}-${keySeq}`;
}

/** The limiter object for one key. */
function stubFor(key: string): DurableObjectStub<RateLimiter> {
  return env.RATE_LIMITER.get(env.RATE_LIMITER.idFromName(key));
}

/** The pending alarm of a limiter object, or null. */
function alarmOf(stub: DurableObjectStub<RateLimiter>): Promise<number | null> {
  return runInDurableObject(stub, (_instance, state) =>
    state.storage.getAlarm()
  );
}

/** The rows the limiter object currently stores. */
function rowsOf(stub: DurableObjectStub<RateLimiter>): Promise<unknown[]> {
  return runInDurableObject(stub, (_instance, state) =>
    state.storage.sql
      .exec("SELECT window_start, window_end, count FROM ratelimit")
      .toArray()
  );
}

/** The `ratelimit` table row in `sqlite_master`, empty once it is dropped. */
function counterTable(
  stub: DurableObjectStub<RateLimiter>
): Promise<unknown[]> {
  return runInDurableObject(stub, (_instance, state) =>
    state.storage.sql
      .exec("SELECT name FROM sqlite_master WHERE name = 'ratelimit'")
      .toArray()
  );
}

/** Wait until the current window has `marginMs` left. */
async function waitForWindowMargin(marginMs = 2_000): Promise<void> {
  while (WINDOW_MS - (Date.now() % WINDOW_MS) < marginMs) {
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

describe("fixed window", () => {
  it("allows exactly the limit and then blocks", async () => {
    const stub = stubFor(nextKey("exact"));
    const limit = 3;

    for (let index = 0; index < limit; index += 1) {
      expect(await stub.hit(limit, WINDOW_MS, WINDOW_START)).toEqual({
        allowed: true,
        retryAfterSeconds: 60
      });
    }

    expect(await stub.hit(limit, WINDOW_MS, WINDOW_START)).toEqual({
      allowed: false,
      retryAfterSeconds: 60
    });
  });

  it("resets the counter in the next window", async () => {
    const stub = stubFor(nextKey("reset"));
    const limit = 2;

    for (let index = 0; index < limit; index += 1) {
      expect(
        (await stub.hit(limit, WINDOW_MS, WINDOW_START)).allowed
      ).toBe(true);
    }
    expect((await stub.hit(limit, WINDOW_MS, WINDOW_START)).allowed).toBe(
      false
    );

    expect(
      (
        await stub.hit(limit, WINDOW_MS, WINDOW_START + WINDOW_MS)
      ).allowed
    ).toBe(true);
  });

  it("does not increment the counter on a blocked call", async () => {
    const stub = stubFor(nextKey("blocked"));
    const limit = 2;

    for (let index = 0; index < limit; index += 1) {
      await stub.hit(limit, WINDOW_MS, WINDOW_START);
    }
    for (let index = 0; index < 5; index += 1) {
      expect((await stub.hit(limit, WINDOW_MS, WINDOW_START)).allowed).toBe(
        false
      );
    }

    // The next window has the full allowance, so blocked calls added nothing.
    const nextWindow = WINDOW_START + WINDOW_MS;
    for (let index = 0; index < limit; index += 1) {
      expect(
        (await stub.hit(limit, WINDOW_MS, nextWindow)).allowed
      ).toBe(true);
    }
    expect((await stub.hit(limit, WINDOW_MS, nextWindow)).allowed).toBe(false);
  });

  it("keeps a separate counter per key", async () => {
    const limited = stubFor(nextKey("key-a"));
    const other = stubFor(nextKey("key-b"));
    const limit = 1;

    expect((await limited.hit(limit, WINDOW_MS, WINDOW_START)).allowed).toBe(
      true
    );
    expect((await limited.hit(limit, WINDOW_MS, WINDOW_START)).allowed).toBe(
      false
    );
    expect((await other.hit(limit, WINDOW_MS, WINDOW_START)).allowed).toBe(
      true
    );
  });
});

describe("concurrent calls", () => {
  it("allows exactly the limit when limit + 10 calls race", async () => {
    const stub = stubFor(nextKey("race"));
    const limit = 5;

    const results = await Promise.all(
      Array.from({ length: limit + 10 }, () =>
        stub.hit(limit, WINDOW_MS, WINDOW_START)
      )
    );

    expect(results.filter((result) => result.allowed)).toHaveLength(limit);
    expect(results.filter((result) => !result.allowed)).toHaveLength(10);
  });
});

describe("retry after", () => {
  it("reports the seconds left in the window", async () => {
    const limit = 1;
    const cases = [
      { offset: 0, expected: 60 },
      { offset: 30_000, expected: 30 },
      { offset: 59_000, expected: 1 },
      { offset: WINDOW_MS - 1, expected: 1 }
    ];

    for (const testCase of cases) {
      const stub = stubFor(nextKey("retry"));
      const now = WINDOW_START + testCase.offset;
      expect((await stub.hit(limit, WINDOW_MS, now)).allowed).toBe(true);
      expect(await stub.hit(limit, WINDOW_MS, now)).toEqual({
        allowed: false,
        retryAfterSeconds: testCase.expected
      });
    }
  });
});

describe("stored data", () => {
  it("clears storage when the alarm runs after the window ended", async () => {
    const stub = stubFor(nextKey("alarm-expired"));
    const pastWindow = alignedWindow(-10);

    expect(await stub.hit(1, WINDOW_MS, pastWindow)).toEqual({
      allowed: true,
      retryAfterSeconds: 60
    });

    // The window ended in the past, so the runtime does not keep an alarm at
    // that end time. Park one in the future (still pending) and run it: the
    // handler reads the expired row and clears the storage.
    await runInDurableObject(stub, (_instance, state) =>
      state.storage.setAlarm(Date.now() + WINDOW_MS)
    );
    await runDurableObjectAlarm(stub);

    await expect.poll(async () => (await counterTable(stub)).length).toBe(0);
    expect(await alarmOf(stub)).toBeNull();

    // The table is gone, so the next hit for a fresh window must create it
    // again and count normally.
    expect(await stub.hit(1, WINDOW_MS, WINDOW_START)).toEqual({
      allowed: true,
      retryAfterSeconds: 60
    });
    expect(await counterTable(stub)).toHaveLength(1);
    expect(await rowsOf(stub)).toEqual([
      {
        window_start: WINDOW_START,
        window_end: WINDOW_START + WINDOW_MS,
        count: 1
      }
    ]);
  });

  it("stores window bounds and count only, never the key", async () => {
    const key = "203.0.113.250:storage-probe";
    const stub = stubFor(key);

    expect((await stub.hit(2, WINDOW_MS, WINDOW_START)).allowed).toBe(true);

    const dump = await runInDurableObject(stub, (_instance, state) => {
      const tables = state.storage.sql
        .exec("SELECT name, sql FROM sqlite_master")
        .toArray();
      const rows = state.storage.sql.exec("SELECT * FROM ratelimit").toArray();
      return JSON.stringify({ tables, rows });
    });

    expect(dump).toContain("ratelimit");
    expect(dump).not.toContain(key);
    expect(dump).not.toContain("203.0.113.250");
  });
});

describe("alarm and window races", () => {
  it("keeps a still-open window and re-arms the alarm to its end", async () => {
    const stub = stubFor(nextKey("alarm-active"));
    const windowStart = alignedWindow(100);
    const windowEnd = windowStart + WINDOW_MS;
    const limit = 2;

    for (let index = 0; index < limit; index += 1) {
      expect(
        (await stub.hit(limit, WINDOW_MS, windowStart)).allowed
      ).toBe(true);
    }

    // The alarm of an older window wakes up while this window is still open.
    expect(await runDurableObjectAlarm(stub)).toBe(true);

    expect(await alarmOf(stub)).toBe(windowEnd);
    expect(await rowsOf(stub)).toEqual([
      { window_start: windowStart, window_end: windowEnd, count: limit }
    ]);

    // The count survived, so the next hit in the window is still blocked.
    expect(await stub.hit(limit, WINDOW_MS, windowStart + 1_000)).toEqual({
      allowed: false,
      retryAfterSeconds: 59
    });
    expect(await alarmOf(stub)).toBe(windowEnd);
  });

  it("arms the alarm only on the first allowed hit of a window", async () => {
    const stub = stubFor(nextKey("alarm-once"));
    const windowStart = alignedWindow(100);
    const windowEnd = windowStart + WINDOW_MS;
    const limit = 2;

    expect(await stub.hit(limit, WINDOW_MS, windowStart)).toEqual({
      allowed: true,
      retryAfterSeconds: 60
    });
    expect(await alarmOf(stub)).toBe(windowEnd);

    // A later allowed hit in the same window does not move the alarm.
    expect(
      await stub.hit(limit, WINDOW_MS, windowStart + 1_000)
    ).toEqual({ allowed: true, retryAfterSeconds: 59 });
    expect(await alarmOf(stub)).toBe(windowEnd);

    // Park the alarm somewhere else, then block. A blocked call does no alarm
    // storage I/O, so the parked value must survive untouched.
    const parked = windowEnd - 1_000;
    await runInDurableObject(stub, (_instance, state) =>
      state.storage.setAlarm(parked)
    );
    expect(
      await stub.hit(limit, WINDOW_MS, windowStart + 2_000)
    ).toEqual({ allowed: false, retryAfterSeconds: 58 });
    expect(await alarmOf(stub)).toBe(parked);
  });

  it("counts a late request for an older window against the open window", async () => {
    const stub = stubFor(nextKey("late-now"));
    const limit = 2;
    const later = alignedWindow(100);
    const earlier = later - WINDOW_MS;

    for (let index = 0; index < limit; index += 1) {
      expect((await stub.hit(limit, WINDOW_MS, later)).allowed).toBe(true);
    }

    // A request stamped in window N arrives after window N+1 is full. It is
    // blocked and must not reset the counter of the open window.
    expect(await stub.hit(limit, WINDOW_MS, earlier)).toEqual({
      allowed: false,
      retryAfterSeconds: 60
    });
    expect((await stub.hit(limit, WINDOW_MS, later)).allowed).toBe(false);

    expect(await rowsOf(stub)).toEqual([
      {
        window_start: later,
        window_end: later + WINDOW_MS,
        count: limit
      }
    ]);
  });

  it("uses the Durable Object clock when hit has no now", async () => {
    const limit = 5;

    // This is the one path with no synthetic `now`, so measure across calls and
    // retry when a window boundary falls inside the measurement. Every
    // assertion holds in any window, so nothing else depends on the clock.
    let result: { allowed: boolean; retryAfterSeconds: number } | null = null;
    let key = "";
    for (let attempt = 0; attempt < 3 && result === null; attempt += 1) {
      await waitForWindowMargin();
      key = nextKey("clock");
      const stub = stubFor(key);
      const before = Date.now();
      for (let index = 0; index < limit; index += 1) {
        expect((await stub.hit(limit, WINDOW_MS)).allowed).toBe(true);
      }
      const candidate = await stub.hit(limit, WINDOW_MS);
      if (
        Math.floor(before / WINDOW_MS) ===
        Math.floor(Date.now() / WINDOW_MS)
      ) {
        result = candidate;
      }
    }

    // A blocked call carries the seconds left in whichever window it hit.
    expect(result).not.toBeNull();
    const blocked = result as { allowed: boolean; retryAfterSeconds: number };
    expect(blocked.allowed).toBe(false);
    expect(blocked.retryAfterSeconds).toBeGreaterThanOrEqual(1);
    expect(blocked.retryAfterSeconds).toBeLessThanOrEqual(60);

    // The stored window is a whole window with the full allowance, whatever
    // minute it belongs to.
    const rows = (await rowsOf(stubFor(key))) as Array<{
      window_start: number;
      window_end: number;
      count: number;
    }>;
    expect(rows).toHaveLength(1);
    expect(rows[0].window_start % WINDOW_MS).toBe(0);
    expect(rows[0].window_end - rows[0].window_start).toBe(WINDOW_MS);
    expect(rows[0].count).toBe(limit);
  });
});

/**
 * Call `hit` inside the object and report the error class. A throw across the
 * RPC boundary is reported as an unhandled rejection by the runtime even when
 * the caller catches it, so validation checks the method in place.
 */
async function errorNameFor(
  limit: number,
  windowMs: number
): Promise<string> {
  const stub = stubFor(nextKey("validation"));
  return runInDurableObject(stub, async (instance) => {
    try {
      await instance.hit(limit, windowMs, WINDOW_START);
      return "no error";
    } catch (error) {
      return error instanceof RangeError ? "RangeError" : String(error);
    }
  });
}

describe("input validation", () => {
  it("rejects a limit that is not a positive finite integer", async () => {
    for (const limit of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(await errorNameFor(limit, WINDOW_MS)).toBe("RangeError");
    }
  });

  it("rejects a window that is not a positive finite integer", async () => {
    for (const windowMs of [
      0,
      -1,
      1.5,
      Number.NaN,
      Number.POSITIVE_INFINITY
    ]) {
      expect(await errorNameFor(1, windowMs)).toBe("RangeError");
    }
  });
});

describe("limitKey helper", () => {
  it("counts through the namespace and returns the same result shape", async () => {
    const key = nextKey("helper");

    expect(await limitKey(env.RATE_LIMITER, key, 1, WINDOW_MS, WINDOW_START))
      .toEqual({ allowed: true, retryAfterSeconds: 60 });
    expect(await limitKey(env.RATE_LIMITER, key, 1, WINDOW_MS, WINDOW_START))
      .toEqual({ allowed: false, retryAfterSeconds: 60 });
  });
});
