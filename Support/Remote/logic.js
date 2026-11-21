// The web remote's logic that needs no page (ADR 0215): choosing a Mac, the tokens' keys,
// range planning and its cache, search request ordering, the event stream's parser and the
// jump bar's letters. RemoteTests runs this file in JavaScriptCore, so it touches no DOM,
// storage or network, and each export is a top-level `export function`, `class` or `const`.

/// Positions in one range of a track list or the queue, as the server reads them at most.
export const RANGE_SIZE = 200;
/// Ranges a list fetches at once.
export const RANGES_IN_FLIGHT = 3;
/// How long a list waits after its last scroll before it fetches, in milliseconds.
export const SETTLE_MS = 100;
/// How long a stream may go without a byte before the page takes it for dead: the server
/// sends a comment every 15 s.
export const SILENT_MS = 40000;
/// How long a stream stays up before its failures count from 0 again.
export const STEADY_MS = 30000;
/// Ranges a list keeps, the least recently used going first.
export const CACHED_RANGES = 20;
/// The longest wait before an event stream connects again, in milliseconds.
export const BACKOFF_CAP_MS = 30000;

/// The Mac to control. `macs` are `{id, paired, state, playedAgo}`, `state` being the
/// stream's "playing", "paused" or "stopped", or null before one arrived, and `playedAgo` what
/// `startedAgo` gives. The one the owner picked wins while it's paired; then the one playing,
/// the one that started most recently among several; then the one controlled last; then the
/// page's own Mac; then any paired one.
export function chooseMac(macs, { picked, lastControlled, own }) {
  const paired = macs.filter((mac) => mac.paired);
  const find = (id) => paired.find((mac) => mac.id === id);
  if (picked && find(picked)) return picked;
  const playing = paired.filter((mac) => mac.state === "playing");
  if (playing.length > 0) {
    return playing.reduce((best, mac) =>
      (mac.playedAgo ?? Infinity) < (best.playedAgo ?? Infinity) ? mac : best
    ).id;
  }
  for (const id of [lastControlled, own]) if (id && find(id)) return id;
  return paired.length > 0 ? paired[0].id : null;
}

/// Seconds since a Mac started playing, now: its `lastPlayedAt` against its own clock when the
/// state was read, `now`, then on the phone's clock since it arrived at `arrivedAt`
/// milliseconds; null when it hasn't played. Macs' clocks may differ by seconds, so no two
/// Macs' times are compared directly.
export function startedAgo(state, arrivedAt, phoneNow) {
  if (!state || state.lastPlayedAt == null) return null;
  return state.now - state.lastPlayedAt + (phoneNow - arrivedAt) / 1000;
}

/// Where a token is kept: the Mac's ID and the origin it paired at, so a token is never sent
/// to another origin that claims the same ID.
export function tokenKey(id, origin) {
  return id + " " + origin;
}

/// Every origin an instance from `/api/instances` can be reached at, lowercased as a
/// browser's `location.origin` is: its `.local` name, then each address.
export function instanceOrigins(instance) {
  const hosts = [instance.host.toLowerCase() + ".local"].concat(
    instance.addresses.map((address) => (address.includes(":") ? "[" + address + "]" : address))
  );
  return hosts.map((host) => ("http://" + host + ":" + instance.port).toLowerCase());
}

/// The origin to talk to `instance` at and its token, `tokens` being an object of tokens by
/// `tokenKey`: an origin it holds a token for, else the `.local` name when the page was opened
/// by one, else its first IPv4 address, then any. `token` is null for an unpaired Mac.
export function reach(instance, tokens, pageOrigin) {
  const origins = instanceOrigins(instance);
  for (const origin of origins) {
    const token = tokens[tokenKey(instance.id, origin)];
    if (token) return { origin, token };
  }
  if (origins.includes(pageOrigin)) return { origin: pageOrigin, token: null };
  const local = pageOrigin.replace(/:\d+$/, "").endsWith(".local");
  const v4 = origins.slice(1).find((origin) => !origin.includes("["));
  return { origin: local ? origins[0] : v4 ?? origins[1] ?? origins[0], token: null };
}

/// The starts of the ranges a list wants with rows `first` to `last` on screen of `total`:
/// those in view and one either side.
export function wantedRanges(first, last, total, size = RANGE_SIZE) {
  if (total <= 0) return [];
  const top = Math.floor(Math.max(0, first) / size) - 1;
  const bottom = Math.floor(Math.min(total - 1, Math.max(first, last)) / size) + 1;
  const starts = [];
  for (let range = Math.max(0, top); range <= bottom && range * size < total; range++) {
    starts.push(range * size);
  }
  return starts;
}

/// The ranges a list holds, by start, keeping the `capacity` used last.
export class RangeCache {
  constructor(capacity = CACHED_RANGES) {
    this.capacity = capacity;
    this.ranges = new Map();
  }

  /// The rows of the range at `start`, marked used, or undefined.
  get(start) {
    const rows = this.ranges.get(start);
    if (rows === undefined) return undefined;
    this.ranges.delete(start);
    this.ranges.set(start, rows);
    return rows;
  }

  has(start) {
    return this.ranges.has(start);
  }

  /// Keeps `rows` at `start` as used last, dropping the least recently used past capacity.
  put(start, rows) {
    this.ranges.delete(start);
    this.ranges.set(start, rows);
    while (this.ranges.size > this.capacity) {
      this.ranges.delete(this.ranges.keys().next().value);
    }
  }

  get starts() {
    return Array.from(this.ranges.keys());
  }
}

/// What a range that arrived does: kept when the list still wants it, dropped otherwise.
export function keepsArrival(start, wanted) {
  return wanted.includes(start);
}

/// Which fetches a list starts and which it aborts, `wanted` being the ranges it wants now,
/// `cached(start)` whether it holds one, and `inFlight` the starts being fetched: those no
/// longer wanted are aborted, and wanted ones start, nearest the view first, while fewer than
/// `cap` are out.
export function planFetches(wanted, cached, inFlight, cap = RANGES_IN_FLIGHT) {
  const abort = inFlight.filter((start) => !wanted.includes(start));
  const kept = inFlight.length - abort.length;
  const start = wanted
    .filter((range) => !cached(range) && !inFlight.includes(range))
    .slice(0, Math.max(0, cap - kept));
  return { start, abort };
}

/// Whether a page of a list says the list changed since the ranges held were read: another
/// library tag, or another length. `held` is `{stamp, total}`, null before any page came.
export function listChanged(held, page) {
  return held !== null && (held.stamp !== page.stamp || held.total !== page.total);
}

/// Search requests in order: at most one in flight, a text typed meanwhile waiting in its
/// place and replacing any that waited before it, and a reply kept only for the text typed
/// last.
export class SearchQueue {
  constructor() {
    this.inFlight = null;
    this.waiting = null;
    this.latest = null;
  }

  /// `text` was typed: the text to send now, or null while another is in flight.
  typed(text) {
    this.latest = text;
    if (this.inFlight !== null) {
      this.waiting = text;
      return null;
    }
    this.inFlight = text;
    return text;
  }

  /// The reply for `text` came, or failed: whether to show it, and the text to send next.
  answered(text) {
    const show = text === this.latest;
    this.inFlight = null;
    const next = this.waiting;
    this.waiting = null;
    if (next !== null && next !== text) this.inFlight = next;
    return { show, next: next !== null && next !== text ? next : null };
  }
}

/// Server-Sent Events from text as it arrives: each `push` gives the data of the events its
/// text completed. Comment lines, which keep a quiet stream open, give nothing.
export class EventParser {
  constructor() {
    this.buffer = "";
    this.data = [];
  }

  push(text) {
    this.buffer += text;
    const events = [];
    let end;
    while ((end = this.buffer.search(/\r\n|\r|\n/)) >= 0) {
      // A `\r` the chunk ends with may be the first half of `\r\n`: wait for the next one.
      if (end === this.buffer.length - 1 && this.buffer[end] === "\r") break;
      const line = this.buffer.slice(0, end);
      const width = this.buffer.startsWith("\r\n", end) ? 2 : 1;
      this.buffer = this.buffer.slice(end + width);
      if (line === "") {
        if (this.data.length > 0) events.push(this.data.join("\n"));
        this.data = [];
      } else if (line.startsWith("data:")) {
        this.data.push(line.slice(line.startsWith("data: ") ? 6 : 5));
      }
    }
    return events;
  }
}

/// How long to wait before connecting a stream again after `failures` in a row.
export function backoff(failures) {
  return Math.min(1000 * Math.pow(2, failures), BACKOFF_CAP_MS);
}

/// The failures in a row once a stream that was up for `upMs` ended: they count from 0 again
/// only after it stayed up `STEADY_MS`, so a stream that drops at once keeps backing off.
export function failuresAfter(failures, upMs) {
  return (upMs >= STEADY_MS ? 0 : failures) + 1;
}

/// Whether a stream last heard from at `heardAt` is dead at `now`, in milliseconds.
export function isSilent(heardAt, now) {
  return now - heardAt > SILENT_MS;
}

/// The jump bar's letters of `names`, as listed: each letter, `#` for a name that doesn't start
/// with one, with the first position it's at. A letter only moves forward, so a name listed out
/// of its letter's place doesn't make an entry.
export function letterOffsets(names) {
  const offsets = [];
  let last = "";
  names.forEach((name, index) => {
    const letter = firstLetter(name);
    if (offsets.length === 0 || letter > last) {
      offsets.push([letter, index]);
      last = letter;
    }
  });
  return offsets;
}

function firstLetter(name) {
  const first = (name ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").charAt(0);
  const upper = first.toUpperCase();
  return upper >= "A" && upper <= "Z" ? upper : "#";
}

/// The playing position now, from `state` as it arrived at `arrivedAt` milliseconds on the
/// phone's clock: on from there while playing. The Mac's own clock isn't used, since it and the
/// phone's may differ by seconds.
export function positionNow(state, arrivedAt, now) {
  if (state.positionSeconds == null) return null;
  const moved = state.state === "playing" ? (now - arrivedAt) / 1000 : 0;
  const duration = state.track?.durationSeconds;
  const position = state.positionSeconds + moved;
  return duration != null ? Math.min(position, duration) : position;
}

/// `seconds` as the clock shows it: "3:07", "1:02:03".
export function clock(seconds) {
  if (seconds == null || !isFinite(seconds)) return "–:––";
  const whole = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor((whole % 3600) / 60);
  const rest = String(whole % 60).padStart(2, "0");
  return hours > 0 ? hours + ":" + String(minutes).padStart(2, "0") + ":" + rest : minutes + ":" + rest;
}

/// Play List's argument for a tap on track `id` of the list `filter` describes, as
/// `/api/tracks` reads it: the list's keys, in a fixed order, and the track to play from.
export function playListArgument(filter, id) {
  const keys = ["genre", "artist", "album", "q", "sort", "descending"].filter((key) => filter[key] != null);
  return keys.map((key) => key + "=" + encodeURIComponent(filter[key])).concat(["playFrom=" + id]).join("&");
}

/// The Mac Browse and Search read from: they stay on the one they were opened on when the
/// page switches Macs by itself (`"auto"`), and follow the chosen Mac when the owner picks one
/// (`"picked"`) or goes back to Browse's top (`"top"`), when there was none, when the bound
/// one is no longer among the `paired` Macs, or while nothing has been opened (`untouched`),
/// so the Mac that answered first doesn't hold them against one that starts playing a moment
/// later.
export function libraryMac(bound, chosen, event, paired, untouched) {
  return bound === null || event !== "auto" || untouched || !paired.includes(bound) ? chosen : bound;
}

/// What the Queue does after an edit: a refused one, as when the queue moved since it was
/// read, reads the queue again at once rather than waiting for the next event.
export function afterQueueEdit(accepted) {
  return accepted ? "wait" : "reload";
}
