import { DurableObject } from "cloudflare:workers";

/**
 * The outcome of one call to `hit`.
 */
export interface RateLimitResult {
  /** True when the call fits inside the limit for the current window. */
  allowed: boolean;
  /** Seconds a blocked caller should wait before the window ends. */
  retryAfterSeconds: number;
}

/**
 * The environment this object needs. The limiter reads no binding, so the type
 * stays generic and a consuming Worker can register the class in any Env.
 */
type RateLimiterEnv = Record<string, unknown>;

/** Window bounds and count for the one row this object keeps. */
type CounterRow = { window_start: number; window_end: number; count: number };

const CREATE_TABLE = `CREATE TABLE IF NOT EXISTS ratelimit (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  window_start INTEGER NOT NULL,
  window_end INTEGER NOT NULL,
  count INTEGER NOT NULL
)`;

const UPSERT_COUNTER = `INSERT INTO ratelimit (id, window_start, window_end, count)
  VALUES (1, ?, ?, ?)
  ON CONFLICT (id) DO UPDATE SET
    window_start = excluded.window_start,
    window_end = excluded.window_end,
    count = excluded.count`;

const SELECT_COUNTER =
  "SELECT window_start, window_end, count FROM ratelimit WHERE id = 1";

const DROP_TABLE = "DROP TABLE IF EXISTS ratelimit";

/**
 * Exact fixed-window rate limiter, one Durable Object per key.
 *
 * Create one object per caller key with `idFromName(key)`. A Durable Object
 * handles one event at a time, and the read, the compare, and the write in
 * `hit` run in one synchronous section with no await between them. Two
 * concurrent calls therefore cannot both pass at the limit.
 *
 * Storage holds the window bounds and the count only. The key lives in the
 * object name, which the runtime never renders into SQL, and this class never
 * logs. The alarm drops the table once the window ends, so an idle key keeps
 * no data.
 *
 * The window comes from the Durable Object's own clock. A caller may pass a
 * synthetic `now` (tests do), but a value earlier than the stored window start
 * is clamped to that start, so a late request for an older window counts
 * against the current one instead of resetting it.
 */
export class RateLimiter extends DurableObject<RateLimiterEnv> {
  /**
   * True once this instance has created the counter table. The constructor
   * sets it, and `alarm` clears it when it drops the table, so a hit after an
   * alarm creates the table again instead of running `CREATE TABLE` on every
   * call.
   */
  #tableReady = false;

  constructor(ctx: DurableObjectState, env: RateLimiterEnv) {
    super(ctx, env);
    this.ensureTable();
  }

  /** Create the counter table for this instance, once, after a drop. */
  private ensureTable(): void {
    if (this.#tableReady) {
      return;
    }
    this.ctx.storage.sql.exec(CREATE_TABLE);
    this.#tableReady = true;
  }

  /**
   * Count one call against a fixed window.
   *
   * `limit` is the number of allowed calls per window and `windowMs` is the
   * window length in milliseconds. Both must be positive integers. A blocked
   * call does not increment the counter.
   */
  async hit(
    limit: number,
    windowMs: number,
    now?: number
  ): Promise<RateLimitResult> {
    if (!Number.isInteger(limit) || limit <= 0) {
      throw new RangeError("limit must be a positive finite integer");
    }
    if (!Number.isInteger(windowMs) || windowMs <= 0) {
      throw new RangeError("windowMs must be a positive finite integer");
    }

    const sql = this.ctx.storage.sql;

    // Section start: no await between the read and the write.
    this.ensureTable();
    const row = sql.exec<CounterRow>(SELECT_COUNTER).toArray()[0];

    // A request stamped before the stored window start is late, not a reason
    // to move the window back. Count it against the window already open.
    const requested = now ?? Date.now();
    const effectiveNow =
      row !== undefined && requested < row.window_start
        ? row.window_start
        : requested;
    const windowStart = Math.floor(effectiveNow / windowMs) * windowMs;
    const windowEnd = windowStart + windowMs;

    // A row from an earlier window carries no count into this one.
    let count =
      row !== undefined && row.window_start === windowStart ? row.count : 0;
    const allowed = count < limit;
    if (allowed) {
      count += 1;
      sql.exec(UPSERT_COUNTER, windowStart, windowEnd, count);
    }
    // Section end.

    // Only the first allowed hit of a window arms the alarm. Later hits and
    // blocked calls leave the existing alarm alone, so the alarm of a window
    // can no longer be moved or dropped by the next window's traffic.
    if (allowed && count === 1) {
      await this.ctx.storage.setAlarm(windowEnd);
    }

    return {
      allowed,
      retryAfterSeconds: Math.max(
        1,
        Math.ceil((windowEnd - effectiveNow) / 1000)
      )
    };
  }

  async alarm(): Promise<void> {
    // Read the row before touching storage. A row whose window is still open
    // belongs to a newer window than the alarm that woke us, so keep it and
    // re-arm instead of dropping a live counter.
    const sql = this.ctx.storage.sql;
    const table = sql
      .exec(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'ratelimit'"
      )
      .toArray()[0];
    if (table === undefined) {
      return;
    }

    const row = sql.exec<CounterRow>(SELECT_COUNTER).toArray()[0];
    if (row !== undefined && row.window_end > Date.now()) {
      await this.ctx.storage.setAlarm(row.window_end);
      return;
    }

    // The window that scheduled this alarm has ended. Dropping the table also
    // drops the row, so an idle object holds nothing. The next hit creates it
    // again through `ensureTable`.
    sql.exec(DROP_TABLE);
    this.#tableReady = false;
  }
}
