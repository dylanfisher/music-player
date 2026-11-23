// The web remote's page (ADR 0215). Every name from a Mac goes on screen through
// `textContent`, never as markup. Logic that needs no page is in logic.js.
import {
  RANGE_SIZE, SETTLE_MS, RangeCache, SearchQueue, EventParser, afterQueueEdit, backoff,
  chooseMac, clock, failuresAfter, isSilent, keepsArrival, letterOffsets, libraryMac,
  SENT_HOLD_MS, listChanged, nowAlbumKey, planFetches, sliderValue, playListArgument, positionNow, reach, scrubbed, startedAgo, tokenKey,
  wantedRanges,
} from "./logic.js";
import { ICONS } from "./icons.js";

const $ = (id) => document.getElementById(id);
const ROW = 40;
const POOL = 40;
const TOKENS = "remote.tokens";
const LAST = "remote.lastControlled";
const INSTANCES_SECONDS = 30;

// MARK: Storage, which a private tab may refuse.

function load(key, fallback) {
  try {
    const text = localStorage.getItem(key);
    return text === null ? fallback : JSON.parse(text);
  } catch (error) {
    console.error("couldn't read " + key, error);
    return fallback;
  }
}

function save(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch (error) {
    say("This browser won't keep the pairing: " + error.message);
  }
}

// MARK: Icons, drawn as DOM nodes so no markup is parsed.

const SVG = "http://www.w3.org/2000/svg";

function icon(name) {
  // Own keys only, so `__proto__` or `constructor` can't name one.
  if (!Object.prototype.hasOwnProperty.call(ICONS, name)) throw new Error("no icon named " + name);
  const data = ICONS[name];
  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("viewBox", "0 0 256 256");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(SVG, "path");
  path.setAttribute("d", data);
  svg.appendChild(path);
  return svg;
}

/// Shows icon `name` in `element`, drawing it only when it changes.
function setIcon(element, name) {
  if (element.dataset.shown === name) return;
  element.dataset.shown = name;
  element.replaceChildren(icon(name));
}

for (const element of document.querySelectorAll("[data-icon]")) setIcon(element, element.dataset.icon);

let tokens = load(TOKENS, {});

function keepToken(id, origin, token) {
  tokens[tokenKey(id, origin)] = token;
  save(TOKENS, tokens);
}

function dropToken(id, origin) {
  delete tokens[tokenKey(id, origin)];
  save(TOKENS, tokens);
}

/// Lists kept under their tags, so an unchanged library costs a 304.
const lists = (() => {
  let opened = null;
  function database() {
    if (!opened) {
      opened = new Promise((resolve, reject) => {
        const request = indexedDB.open("remote-lists", 1);
        request.onupgradeneeded = () => request.result.createObjectStore("lists");
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
    }
    return opened;
  }
  async function run(mode, use) {
    const db = await database();
    return new Promise((resolve, reject) => {
      const request = use(db.transaction("lists", mode).objectStore("lists"));
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }
  return {
    get: (key) => run("readonly", (store) => store.get(key)).catch((error) => {
      console.error("the list cache can't be read", error);
      return undefined;
    }),
    put: (key, value) => run("readwrite", (store) => store.put(value, key)).catch((error) => {
      console.error("the list cache can't be written", error);
    }),
  };
})();

// MARK: Messages.

let messageTimer = 0;

function say(text) {
  const message = $("message");
  message.textContent = text;
  message.hidden = false;
  clearTimeout(messageTimer);
  messageTimer = setTimeout(() => (message.hidden = true), 4000);
}

// MARK: Macs.

/// Each Mac `/api/instances` lists, by ID: where to reach it, its token, and its stream.
const macs = new Map();
let ownID = null;
let picked = null;
let chosenID = null;

class Mac {
  constructor(instance) {
    this.id = instance.id;
    this.update(instance);
    this.state = null;
    this.arrivedAt = 0;
    this.online = false;
    this.failures = 0;
    this.stream = null;
    this.retry = 0;
  }

  update(instance) {
    this.instance = instance;
    this.name = instance.name;
    const reached = reach(instance, tokens, location.origin);
    if (reached.origin !== this.origin || reached.token !== this.token) this.close();
    this.origin = reached.origin;
    this.token = reached.token;
  }

  get paired() {
    return this.token !== null;
  }

  headers(more = {}) {
    return Object.assign({ Authorization: "Bearer " + this.token }, more);
  }

  /// A request to this Mac; a 401 means it forgot this phone, which then pairs again.
  async fetch(path, options = {}) {
    const response = await fetch(this.origin + path, Object.assign({ cache: "no-store" }, options, {
      headers: this.headers(options.headers),
    }));
    if (response.status === 401) {
      this.forgotten();
      throw new Error(this.name + " no longer knows this phone; pair it again");
    }
    return response;
  }

  async json(path, options = {}) {
    const response = await this.fetch(path, options);
    if (!response.ok) throw new Error(await problem(response));
    return response.json();
  }

  forgotten() {
    dropToken(this.id, this.origin);
    this.token = null;
    this.close();
    this.state = null;
    render();
  }

  connect() {
    if (!this.paired || this.stream || document.hidden) return;
    clearTimeout(this.retry);
    const controller = new AbortController();
    this.stream = controller;
    this.upSince = null;
    this.heardAt = Date.now();
    this.read(controller).catch((error) => {
      if (!controller.signal.aborted) this.failed(error);
    });
  }

  /// The stream failed, ended or went quiet: connect again after a backoff.
  failed(error) {
    if (this.stream) this.stream.abort();
    this.stream = null;
    this.online = false;
    renderStrip();
    this.failures = failuresAfter(this.failures, this.upSince === null ? 0 : Date.now() - this.upSince);
    const wait = backoff(this.failures - 1);
    console.warn(this.name + "'s events stopped; again in " + wait + " ms", error);
    this.retry = setTimeout(() => this.connect(), wait);
  }

  async read(controller) {
    const response = await this.fetch("/api/events", { signal: controller.signal });
    if (!response.ok) throw new Error(await problem(response));
    this.upSince = Date.now();
    if (nowAlbum.failed === this) nowAlbum.key = null;
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    const parser = new EventParser();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) throw new Error("the stream ended");
      // Any byte, the server's comments included, shows the stream is alive.
      this.heardAt = Date.now();
      for (const data of parser.push(decoder.decode(value, { stream: true }))) {
        this.online = true;
        this.state = JSON.parse(data);
        this.arrivedAt = Date.now();
        stateChanged(this);
      }
    }
  }

  close() {
    clearTimeout(this.retry);
    if (this.stream) this.stream.abort();
    this.stream = null;
    this.online = false;
  }
}

// A stream the network dropped without closing hears nothing, not even the comments.
setInterval(() => {
  for (const mac of macs.values()) {
    if (mac.stream && isSilent(mac.heardAt, Date.now())) mac.failed(new Error("nothing heard"));
  }
}, 5000);

async function problem(response) {
  try {
    const body = await response.json();
    if (body && typeof body.error === "string") return body.error;
  } catch (error) {
    console.error("an error reply that isn't JSON", error);
  }
  return "the Mac answered " + response.status;
}

/// The Mac the page talks to: the one `chooseMac` picks.
function chosen() {
  return chosenID ? macs.get(chosenID) ?? null : null;
}

async function refreshInstances() {
  const own = Array.from(macs.values()).find((mac) => mac.origin === location.origin && mac.paired);
  const token = own ? own.token : ownToken();
  if (!token) {
    render();
    if (!pairing.open) askToPair(null);
    return;
  }
  let instances;
  try {
    const response = await fetch(location.origin + "/api/instances", {
      cache: "no-store",
      headers: { Authorization: "Bearer " + token },
    });
    if (response.status === 401) {
      for (const key of Object.keys(tokens)) {
        if (key.endsWith(" " + location.origin)) delete tokens[key];
      }
      save(TOKENS, tokens);
      askToPair(null);
      return;
    }
    if (!response.ok) throw new Error(await problem(response));
    instances = await response.json();
  } catch (error) {
    say("This Mac can't be reached: " + error.message);
    return;
  }
  ownID = instances.length > 0 ? instances[0].id : null;
  const seen = new Set();
  for (const instance of instances) {
    seen.add(instance.id);
    const mac = macs.get(instance.id);
    if (mac) mac.update(instance);
    else macs.set(instance.id, new Mac(instance));
  }
  for (const [id, mac] of macs) {
    if (!seen.has(id)) {
      mac.close();
      macs.delete(id);
    }
  }
  for (const mac of macs.values()) mac.connect();
  choose();
  render();
}

/// The token for the page's own Mac, whose ID the page learns from it.
function ownToken() {
  for (const [key, token] of Object.entries(tokens)) {
    if (key.endsWith(" " + location.origin)) return token;
  }
  return null;
}

/// Chooses the Mac to control; `event` is "auto" when the page does it by itself, as when
/// playback moves, and "picked" when the owner picks one.
function choose(event = "auto") {
  const next = chooseMac(
    Array.from(macs.values()).map((mac) => ({
      id: mac.id, paired: mac.paired, state: mac.state ? mac.state.state : null,
      playedAgo: startedAgo(mac.state, mac.arrivedAt, Date.now()),
    })),
    { picked, lastControlled: load(LAST, null), own: ownID }
  );
  if (next !== chosenID) {
    chosenID = next;
    // The queue and Now Playing are the chosen Mac's at once.
    queueView.stamp = null;
    if (!$("view-queue").hidden) queueView.reload();
  }
  bindLibrary(event);
}

/// The Mac Browse and Search read from: the chosen one unless the page switched by itself.
let libraryID = null;

function library() {
  return libraryID ? macs.get(libraryID) ?? null : null;
}

function pairedIDs() {
  return Array.from(macs.values()).filter((mac) => mac.paired).map((mac) => mac.id);
}

/// Browse is at its top and no search is shown: a change of Mac loses nothing.
function browseUntouched() {
  return browse.stack.length <= 1 && $("results").childElementCount === 0;
}

function bindLibrary(event) {
  const bound = libraryMac(libraryID, chosenID, event, pairedIDs(), browseUntouched());
  if (bound === libraryID) return;
  libraryID = bound;
  libraryChanged();
}

function stateChanged(mac) {
  const before = chosenID;
  choose();
  renderStrip();
  if (mac.id === chosenID || before !== chosenID) renderNow();
  if (mac.id === chosenID && queueView.stamp !== mac.state.queueStamp) queueView.reload();
}

// MARK: Pairing.

const pairing = { open: false, mac: null };

function askToPair(mac) {
  pairing.open = true;
  pairing.mac = mac;
  $("pair-title").textContent = mac ? "Pair with " + mac.name : "Pair with this Mac";
  $("pair-name").textContent = mac ? mac.name : "the Mac this page came from";
  $("pair-problem").textContent = "";
  $("pair-code").value = "";
  $("pairing").hidden = false;
  $("pair-code").focus();
}

function closePairing() {
  pairing.open = false;
  $("pairing").hidden = true;
}

function deviceName() {
  const agent = navigator.userAgent;
  const device = /iPad/.test(agent) ? "iPad" : /iPhone/.test(agent) ? "iPhone" : /Mac/.test(agent) ? "Mac" : "Phone";
  return device + ", Safari";
}

async function pair(code) {
  const mac = pairing.mac;
  const origin = mac ? mac.origin : location.origin;
  const response = await fetch(origin + "/api/pair", {
    method: "POST",
    cache: "no-store",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code, device: deviceName() }),
  });
  if (!response.ok) throw new Error(await problem(response));
  const paired = await response.json();
  if (mac && paired.instance !== mac.id) {
    throw new Error("another Mac answered at " + origin + ", so its token wasn't kept");
  }
  keepToken(paired.instance, origin, paired.token);
  if (mac) mac.update(mac.instance);
  closePairing();
  await refreshInstances();
}

$("pair-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const code = $("pair-code").value.trim();
  if (!/^[0-9]{6}$/.test(code)) {
    $("pair-problem").textContent = "The code is six digits.";
    return;
  }
  pair(code).catch((error) => ($("pair-problem").textContent = error.message));
});

$("pair-cancel").addEventListener("click", closePairing);

// MARK: Commands.

/// Runs a command on `mac`, the chosen one unless a list from another Mac's library asks;
/// whether the Mac took it.
async function command(name, argument, mac = chosen()) {
  if (!mac) return false;
  save(LAST, mac.id);
  try {
    const body = argument === undefined ? { name } : { name, argument: String(argument) };
    const response = await mac.fetch("/api/command", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (response.ok) return true;
    say(await problem(response));
  } catch (error) {
    say(error.message);
  }
  return false;
}

// MARK: Covers, fetched with the token and shown from blobs, kept by URL.

const covers = new Map();
const COVERS_KEPT = 300;

function coverURL(mac, id, size) {
  return mac.origin + "/api/art/" + size + "/" + encodeURIComponent(id);
}

async function cover(mac, id, size) {
  const url = coverURL(mac, id, size);
  if (covers.has(url)) {
    const kept = covers.get(url);
    covers.delete(url);
    covers.set(url, kept);
    return kept;
  }
  const made = mac.fetch("/api/art/" + size + "/" + encodeURIComponent(id), { cache: "default" })
    .then((response) => (response.ok ? response.blob() : null))
    .then((blob) => (blob ? URL.createObjectURL(blob) : null))
    .catch((error) => {
      // Not kept, so the next showing asks again.
      covers.delete(url);
      throw error;
    });
  covers.set(url, made);
  while (covers.size > COVERS_KEPT) {
    const [oldest, kept] = covers.entries().next().value;
    covers.delete(oldest);
    kept.then((blobURL) => blobURL && URL.revokeObjectURL(blobURL));
  }
  return made;
}

/// Shows cover `id` in `image`, unless the image was reused for another meanwhile.
function showCover(image, mac, id, size) {
  image.dataset.cover = id || "";
  if (!id || !mac) {
    image.removeAttribute("src");
    return;
  }
  cover(mac, id, size).then(
    (url) => {
      if (image.dataset.cover !== id) return;
      if (url) image.src = url;
      else image.removeAttribute("src");
    },
    (error) => console.error("a cover didn't load", error)
  );
}

// MARK: The virtual list: fixed-height rows over a spacer as tall as all of them, and a pool
// of row elements reused for what's on screen.

class VirtualList {
  /// `source` gives `total`, `row(index)` (undefined until loaded), `need(first, last)`, and
  /// `render(element, row, index)`; `rowHeight` is in pixels, and `scroll` where it starts.
  constructor(container, source, rowHeight = ROW, scroll = 0) {
    this.container = container;
    this.source = source;
    this.rowHeight = rowHeight;
    this.spacer = document.createElement("div");
    this.spacer.className = "spacer";
    this.rows = [];
    container.replaceChildren(this.spacer);
    this.spacer.style.height = source.total() * rowHeight + "px";
    container.scrollTop = scroll;
    for (let i = 0; i < POOL; i++) {
      const element = document.createElement("div");
      element.className = "row";
      element.hidden = true;
      this.spacer.appendChild(element);
      this.rows.push(element);
    }
    this.frame = 0;
    container.onscroll = () => {
      if (!this.frame) this.frame = requestAnimationFrame(() => this.draw());
    };
    this.draw();
  }

  get visible() {
    const top = this.container.scrollTop;
    const first = Math.max(0, Math.floor(top / this.rowHeight));
    const count = Math.ceil(this.container.clientHeight / this.rowHeight) + 1;
    return [first, Math.min(this.source.total() - 1, first + count - 1)];
  }

  draw() {
    this.frame = 0;
    const total = this.source.total();
    this.spacer.style.height = total * this.rowHeight + "px";
    const [first, last] = this.visible;
    if (total > 0) this.source.need(first, last);
    const start = Math.max(0, first - 4);
    this.rows.forEach((element, slot) => {
      const index = start + slot;
      if (index >= total) {
        element.hidden = true;
        return;
      }
      element.hidden = false;
      element.style.height = this.rowHeight + "px";
      element.style.transform = "translateY(" + index * this.rowHeight + "px)";
      if (element.dataset.index !== String(index) || element.dataset.stale !== "0") {
        element.dataset.index = String(index);
        const row = this.source.row(index);
        element.dataset.stale = row === undefined ? "1" : "0";
        this.source.render(element, row, index);
      }
    });
  }

  /// Draws every row again, as after its data arrived.
  refresh() {
    for (const element of this.rows) element.dataset.stale = "1";
    this.draw();
  }

  scrollTo(index) {
    this.container.scrollTop = index * this.rowHeight;
    this.draw();
  }
}

const RETRIES = 3;
const RETRY_MS = 2000;

/// A list read a range at a time by position: the tracks of a filter, or the queue.
class RangedSource {
  constructor(path, render, onPage, mac = chosen()) {
    this.path = path;
    this.renderRow = render;
    this.onPage = onPage;
    this.cache = new RangeCache();
    /// The fetches out, by start, each with its `AbortController`.
    this.loading = new Map();
    this.count = 0;
    this.wanted = [];
    this.list = null;
    this.mac = mac;
    /// The tag and length the ranges held were read under, null before the first came.
    this.held = null;
    this.settle = 0;
    /// Failed fetches by start, so a range is read again a bounded number of times.
    this.failures = new Map();
  }

  /// The list is replaced: stop its timer and its fetches.
  dispose() {
    clearTimeout(this.settle);
    for (const controller of this.loading.values()) controller.abort();
    this.loading.clear();
    this.wanted = [];
  }

  total() {
    return this.count;
  }

  row(index) {
    const start = Math.floor(index / RANGE_SIZE) * RANGE_SIZE;
    const rows = this.cache.ranges.get(start);
    return rows ? rows[index - start] : undefined;
  }

  /// Rows `first` to `last` are on screen: once scrolling has settled, fetch what they want.
  /// During a fast flick nothing is fetched, and the rows show as placeholders.
  need(first, last) {
    this.wanted = wantedRanges(first, last, this.count);
    for (const start of this.wanted) this.cache.get(start);
    clearTimeout(this.settle);
    this.settle = setTimeout(() => this.fetch(), SETTLE_MS);
  }

  fetch() {
    const plan = planFetches(this.wanted, (start) => this.cache.has(start), Array.from(this.loading.keys()));
    for (const start of plan.abort) {
      this.loading.get(start).abort();
      this.loading.delete(start);
    }
    for (const start of plan.start) this.load(start);
  }

  load(start) {
    if (!this.mac) return;
    const controller = new AbortController();
    this.loading.set(start, controller);
    const separator = this.path.includes("?") ? "&" : "?";
    this.mac.json(this.path + separator + "offset=" + start + "&limit=" + RANGE_SIZE, { signal: controller.signal }).then(
      (page) => {
        if (this.loading.get(start) !== controller) return;
        this.loading.delete(start);
        this.failures.delete(start);
        if (this.onPage && this.onPage(page) === false) return;
        if (listChanged(this.held, page)) {
          // The library or the list changed: what's held is of another list. The scroll
          // position stays, and what's in view is read again.
          for (const other of this.loading.values()) other.abort();
          this.loading.clear();
          this.cache = new RangeCache();
        }
        this.held = { stamp: page.stamp, total: page.total };
        this.count = page.total;
        if (keepsArrival(start, this.wanted)) this.cache.put(start, page.rows);
        if (this.list) this.list.refresh();
        this.fetch();
      },
      (error) => {
        if (controller.signal.aborted) return;
        this.loading.delete(start);
        say(error.message);
        // A transient error would otherwise leave placeholders until the next scroll.
        const failed = (this.failures.get(start) ?? 0) + 1;
        this.failures.set(start, failed);
        if (failed <= RETRIES) setTimeout(() => this.wanted.includes(start) && this.fetch(), RETRY_MS);
      }
    );
  }

  render(element, row, index) {
    this.renderRow(element, row, index);
  }
}

/// A list read whole, its tag kept in IndexedDB with it.
async function wholeList(mac, path) {
  const key = mac.id + " " + mac.origin + " " + path;
  const kept = await lists.get(key);
  const response = await mac.fetch(path, {
    headers: kept ? { "If-None-Match": kept.tag } : {},
  });
  if (response.status === 304 && kept) return kept.body;
  if (!response.ok) throw new Error(await problem(response));
  const body = await response.json();
  const tag = response.headers.get("ETag");
  if (tag) lists.put(key, { tag, body });
  return body;
}

function fillRow(element, { line1, line2, add, placeholder, playing }) {
  element.replaceChildren();
  element.classList.toggle("placeholder", !!placeholder);
  element.classList.toggle("current", !!playing);
  if (playing) {
    const mark = icon("speakerHigh");
    mark.classList.add("playing-mark");
    element.appendChild(mark);
  }
  const texts = document.createElement("div");
  texts.className = "texts";
  const first = document.createElement("div");
  first.className = "line1";
  first.textContent = line1 || " ";
  texts.appendChild(first);
  if (line2 !== undefined) {
    const second = document.createElement("div");
    second.className = "line2";
    second.textContent = line2 || " ";
    texts.appendChild(second);
  }
  element.appendChild(texts);
  if (add) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "add";
    button.appendChild(icon("plus"));
    button.setAttribute("aria-label", "Add to the queue");
    button.addEventListener("click", (event) => {
      event.stopPropagation();
      add();
    });
    element.appendChild(button);
  }
}

function placeholder(element) {
  fillRow(element, { line1: "Loading", line2: "", placeholder: true });
}

function joined(...parts) {
  return parts.filter((part) => part).join(" — ");
}

// MARK: Now Playing.

function renderNow() {
  const mac = chosen();
  const state = mac ? mac.state : null;
  const track = state ? state.track : null;
  $("now-title").textContent = track ? track.title : mac ? "Nothing playing" : "No Mac";
  $("now-subtitle").textContent = track ? joined(track.artist, track.album) : mac ? mac.name : "";
  showCover($("now-cover"), mac, track ? track.art : null, "l");
  setIcon($("play"), state && state.state === "playing" ? "pause" : "play");
  $("shuffle").classList.toggle("on", !!(state && state.shuffle));
  $("repeat").classList.toggle("on", !!(state && state.repeatMode !== "off"));
  setIcon($("repeat"), state && state.repeatMode === "one" ? "repeatOne" : "repeat");
  const duration = track ? track.durationSeconds : null;
  $("seek").max = duration ? String(Math.floor(duration)) : "1";
  $("seek").disabled = !duration;
  const volume = state ? state.volumeDecibels : null;
  $("volume-row").hidden = volume == null;
  if (volume != null && !volumeDragging) {
    $("volume").min = String(state.volumeFloorDecibels ?? -60);
    $("volume").value = String(volume);
    $("volume-text").textContent = Math.round(volume) + " dB";
  }
  $("output").textContent = state && state.output ? "Playing through " + state.output.name : "";
  renderReceiver(state ? state.receiver : null);
  renderNowAlbum(mac, track);
  tick();
}

/// The playing track's album, read once per Mac and album; a track change within it only moves
/// the mark.
const nowAlbum = { key: null, rows: [], playing: null, failed: null };

function renderNowAlbum(mac, track) {
  const album = track ? track.albumID : null;
  const key = mac && mac.paired ? nowAlbumKey(mac.id, mac.origin, track) : null;
  if (key !== nowAlbum.key) {
    nowAlbum.key = key;
    nowAlbum.failed = null;
    nowAlbum.rows = [];
    $("now-album").replaceChildren();
    $("now-album").hidden = true;
    if (key !== null) {
      readAlbum(mac, album).then(
        (rows) => {
          if (nowAlbum.key !== key) return;
          nowAlbum.rows = rows.map((row) => {
            const element = document.createElement("div");
            element.className = "row";
            return { row, element };
          });
          nowAlbum.playing = null;
          $("now-album").replaceChildren(...nowAlbum.rows.map(({ element }) => element));
          $("now-album").hidden = rows.length === 0;
          markPlaying(mac, album, mac.state && mac.state.track ? mac.state.track.id : null, true);
        },
        (error) => {
          if (nowAlbum.key !== key) return;
          // Read again at the next album or when the Mac's stream connects again.
          nowAlbum.failed = mac;
          say(error.message);
        }
      );
    }
  }
  if (key !== null) markPlaying(mac, album, track.id, false);
}

/// Draws the rows whose mark changes, or every row when `all`.
function markPlaying(mac, album, id, all) {
  if (!all && id === nowAlbum.playing) return;
  for (const { row, element } of nowAlbum.rows) {
    if (all || row[0] === id || row[0] === nowAlbum.playing) albumTrack(element, row, album, mac, row[0] === id);
  }
  nowAlbum.playing = id;
}

/// The album's tracks, in the order the album view lists them, a range at a time.
async function readAlbum(mac, album) {
  const rows = [];
  for (;;) {
    const page = await mac.json(
      "/api/tracks?" + query({ album, sort: "album", offset: rows.length, limit: RANGE_SIZE })
    );
    rows.push(...page.rows);
    if (page.rows.length === 0 || rows.length >= page.total) return rows;
  }
}

let seeking = false;
let volumeDragging = false;
let receiverDragging = false;
/// The receiver volume last sent, { value, at }, shown until the state echoes it.
let receiverSent = null;

/// Moves the bar on between events, which come only when something changes.
function tick() {
  const mac = chosen();
  const state = mac ? mac.state : null;
  const position = state ? positionNow(state, mac.arrivedAt, Date.now()) : null;
  const duration = state && state.track ? state.track.durationSeconds : null;
  if (!seeking) $("seek").value = String(Math.floor(position ?? 0));
  const shown = seeking ? Number($("seek").value) : position;
  $("elapsed").textContent = clock(shown);
  $("remaining").textContent = duration != null && shown != null ? "-" + clock(duration - shown) : "–:––";
}

setInterval(() => {
  if (!document.hidden && !$("view-now").hidden) tick();
}, 500);

function renderReceiver(receiver) {
  $("receiver").hidden = !receiver;
  if (!receiver) return;
  $("receiver-power").textContent = receiver.isOn === false ? "Standby" : "On";
  $("receiver-power").classList.toggle("on", receiver.isOn !== false);
  $("receiver-mute").classList.toggle("on", !!receiver.isMuted);
  const slider = $("receiver-slider");
  slider.hidden = receiver.volumeFloorDecibels == null || receiver.volumeCeilingDecibels == null;
  slider.disabled = receiver.volumeDecibels == null;
  if (!receiverDragging) {
    if (!slider.hidden) {
      slider.min = String(receiver.volumeFloorDecibels);
      slider.max = String(receiver.volumeCeilingDecibels);
    }
    const shown = sliderValue(receiver.volumeDecibels, receiverSent, Date.now());
    if (shown === receiver.volumeDecibels) receiverSent = null;
    if (shown != null) slider.value = String(shown);
    $("receiver-volume").textContent = shown != null ? shown + " dB" : "–";
  }
  const select = $("receiver-input");
  if (select.options.length !== receiver.inputs.length) {
    select.replaceChildren();
    for (const input of receiver.inputs) {
      const option = document.createElement("option");
      option.value = input.command;
      option.textContent = input.title;
      option.dataset.value = input.value;
      select.appendChild(option);
    }
  }
  for (const option of select.options) option.selected = option.dataset.value === receiver.input;
}

$("play").addEventListener("click", () => command("playback.playPause"));
$("previous").addEventListener("click", () => command("playback.previous"));
$("next").addEventListener("click", () => command("playback.next"));
$("shuffle").addEventListener("click", () => command("playback.shuffle"));
$("repeat").addEventListener("click", () => {
  const mode = chosen()?.state?.repeatMode;
  command(mode === "off" ? "playback.repeatAll" : mode === "all" ? "playback.repeatOne" : "playback.repeatOff");
});
$("seek").addEventListener("input", () => {
  seeking = true;
  tick();
});
$("seek").addEventListener("change", () => {
  seeking = false;
  command("playback.seekTo", $("seek").value);
});
$("volume").addEventListener("input", () => {
  volumeDragging = true;
  $("volume-text").textContent = $("volume").value + " dB";
});
$("volume").addEventListener("change", () => {
  volumeDragging = false;
  command("playback.setAppVolume", $("volume").value);
});
$("receiver-slider").addEventListener("input", () => {
  receiverDragging = true;
  $("receiver-volume").textContent = $("receiver-slider").value + " dB";
});
$("receiver-slider").addEventListener("change", () => {
  receiverDragging = false;
  receiverSent = { value: Number($("receiver-slider").value), at: Date.now() };
  command("receiver.setVolume", $("receiver-slider").value);
  // Back to the state's value if it never echoes this one.
  setTimeout(renderNow, SENT_HOLD_MS);
});
// A cancelled touch sends no `change`: the slider goes back to following the state.
for (const name of ["pointercancel", "touchcancel", "blur"]) {
  $("receiver-slider").addEventListener(name, () => {
    if (!receiverDragging) return;
    receiverDragging = false;
    renderNow();
  });
}
$("receiver-up").addEventListener("click", () => command("receiver.raiseVolume"));
$("receiver-down").addEventListener("click", () => command("receiver.lowerVolume"));
$("receiver-mute").addEventListener("click", () => command("receiver.mute"));
$("receiver-power").addEventListener("click", () => {
  const on = chosen()?.state?.receiver?.isOn !== false;
  command(on ? "receiver.standby" : "receiver.powerOn");
});
$("receiver-input").addEventListener("change", () => command($("receiver-input").value));

// MARK: Queue.

const queueView = {
  stamp: null,
  selected: null,
  source: null,
  list: null,

  /// Reads the queue again from the start; `stamp` is the one a range said it has now.
  reload(stamp) {
    const mac = chosen();
    this.selected = null;
    $("queue-actions").hidden = true;
    if (!mac || !mac.paired) {
      this.stamp = null;
      $("queue-list").replaceChildren();
      $("queue-count").textContent = "";
      return;
    }
    this.stamp = stamp ?? (mac.state ? mac.state.queueStamp : null);
    if ($("view-queue").hidden) return;
    if (this.source) this.source.dispose();
    const source = new RangedSource("/api/queue", (element, row, index) => this.render(element, row, index), (page) => {
      // A range from before the queue changed names other tracks: start over.
      if (this.stamp !== null && page.stamp !== this.stamp) {
        this.reload(page.stamp);
        return false;
      }
      this.stamp = page.stamp;
      this.position = page.position;
      $("queue-count").textContent = page.total === 1 ? "1 track" : page.total + " tracks";
      return true;
    });
    this.source = source;
    source.count = 1;
    this.list = new VirtualList($("queue-list"), source);
    source.list = this.list;
  },

  render(element, row, index) {
    if (row === undefined) return placeholder(element);
    fillRow(element, { line1: row[1], line2: joined(row[2], row[3]) });
    element.classList.toggle("current", index === this.position);
    element.classList.toggle("selected", index === this.selected);
    element.onclick = () => {
      this.selected = this.selected === index ? null : index;
      $("queue-actions").hidden = this.selected === null;
      this.list.refresh();
    };
  },

  edit(name, ...places) {
    if (this.selected === null || this.stamp === null) return;
    command(name, [this.stamp, ...places].join(":")).then((accepted) => {
      if (afterQueueEdit(accepted) === "reload") this.reload();
    });
    this.selected = null;
    $("queue-actions").hidden = true;
  },
};

$("queue-up").addEventListener("click", () => {
  const at = queueView.selected;
  if (at > 0) queueView.edit("queue.moveItem", at, at - 1);
});
$("queue-down").addEventListener("click", () => {
  const at = queueView.selected;
  if (at !== null && at + 1 < queueView.source.count) queueView.edit("queue.moveItem", at, at + 2);
});
$("queue-next").addEventListener("click", () => {
  const at = queueView.selected;
  const after = (queueView.position ?? -1) + 1;
  if (at !== null && at !== queueView.position) queueView.edit("queue.moveItem", at, after);
});
$("queue-remove").addEventListener("click", () => queueView.edit("queue.removeItem", queueView.selected));

// MARK: Browse.

/// Where Browse is: a stack of levels, each a list of one kind with the filter that led to it.
const browse = { kind: "artists", stack: [], list: null };

function level() {
  return browse.stack[browse.stack.length - 1];
}

function query(filter) {
  return Object.entries(filter)
    .map(([key, value]) => key + "=" + encodeURIComponent(value))
    .join("&");
}

function openLevel(next) {
  // Kept, so Back comes back to the same place in the list.
  if (level()) {
    level().scroll = $("browse-list").scrollTop;
    if (browse.list) level().total = browse.list.source.total();
  }
  browse.stack.push(next);
  showLevel();
}

function disposeBrowseList() {
  if (browse.list && browse.list.source.dispose) browse.list.source.dispose();
}

function showLevel() {
  disposeBrowseList();
  const current = level();
  const mac = library();
  renderLibraryName();
  $("back").hidden = browse.stack.length <= 1;
  $("kinds").hidden = browse.stack.length > 1;
  $("browse-title").textContent = current.title;
  $("browse-play").hidden = !current.album;
  $("browse-queue").hidden = !current.album;
  $("jump").replaceChildren();
  $("browse-list").classList.remove("lettered");
  $("scrub").hidden = true;
  if (!mac || !mac.paired) {
    $("browse-list").replaceChildren(empty("No Mac to browse"));
    return;
  }
  if (current.kind === "tracks") return showTracks(current, mac);
  if (current.kind === "grid") return showGrid(current, mac);
  showEntries(current, mac);
}

function empty(text) {
  const element = document.createElement("p");
  element.className = "empty";
  element.textContent = text;
  return element;
}

const routes = { genres: "/api/genres", artists: "/api/artists", albums: "/api/albums" };

function showEntries(current, mac) {
  const path = routes[current.kind] + (Object.keys(current.filter).length ? "?" + query(current.filter) : "");
  const shown = current;
  $("browse-list").replaceChildren(empty("Loading"));
  wholeList(mac, path).then(
    (list) => {
      if (level() !== shown || library() !== mac) return;
      // An artist's albums start with all of the artist's songs.
      const rows = current.kind === "albums" && current.filter.artist != null
        ? [ALL_SONGS].concat(list.rows)
        : list.rows;
      if (rows.length === 0) return $("browse-list").replaceChildren(empty("Nothing here"));
      const source = {
        total: () => rows.length,
        row: (index) => rows[index],
        need: () => {},
        render: (element, row) => {
          fillRow(element, { line1: row[1], line2: current.kind === "albums" ? row[2] ?? "" : undefined });
          element.onclick = () =>
            row === ALL_SONGS
              ? openLevel({ kind: "tracks", title: current.title, filter: { artist: current.filter.artist, sort: "album" } })
              : enter(current, row);
        },
      };
      browse.list = new VirtualList($("browse-list"), source, ROW, current.scroll ?? 0);
      jumpBar(rows.map((row) => row[1]), browse.list);
      scrubber(browse.list, (index) => rows[index][1]);
    },
    (error) => $("browse-list").replaceChildren(empty(error.message))
  );
}

const ALL_SONGS = [null, "All Songs", null];

function enter(current, row) {
  const [id, name] = row;
  if (current.kind === "genres") {
    openLevel({ kind: "artists", title: name, filter: { genre: id } });
  } else if (current.kind === "artists") {
    openLevel({ kind: "albums", title: name, filter: Object.assign({}, current.filter, { artist: id }) });
  } else {
    openLevel({ kind: "tracks", title: name, album: id, filter: { album: id, sort: "album" } });
  }
}

/// A track of `album` in a list of its tracks: a tap plays the album from it.
function albumTrack(element, row, album, mac, playing = false) {
  fillRow(element, {
    line1: row[1],
    line2: row[2] ?? "",
    add: row[0] != null ? () => command("playback.queueTracks", "tracks:" + row[0], mac) : null,
    playing,
  });
  element.onclick = () => {
    if (row[0] != null) command("playback.playTracks", "album:" + album + ":" + row[0], mac);
  };
}

function showTracks(current, mac) {
  const source = new RangedSource("/api/tracks?" + query(current.filter), (element, row, index) => {
    if (row === undefined) return placeholder(element);
    if (current.album) return albumTrack(element, row, current.album, mac);
    fillRow(element, {
      line1: row[1],
      line2: joined(row[2], row[3]),
      add: row[0] != null ? () => command("playback.queueTracks", "tracks:" + row[0], mac) : null,
    });
    // The whole list, as the Mac reads it, from this track.
    element.onclick = () => {
      if (row[0] != null) command("playback.playList", playListArgument(current.filter, row[0]), mac);
    };
  }, null, mac);
  // The length it had, so the place Back returns to is in the list before its first range.
  source.count = current.total ?? 1;
  browse.list = new VirtualList($("browse-list"), source, ROW, current.scroll ?? 0);
  source.list = browse.list;
  // A track by its artist, as Songs is sorted, or by its title in an album.
  scrubber(browse.list, (index) => {
    const row = source.row(index);
    return row === undefined ? null : current.album ? row[1] : row[2] ?? row[1];
  });
}

/// The album grid: rows of covers, each row a few albums, with their covers' IDs read for the
/// rows in view.
function showGrid(current, mac) {
  const shown = current;
  $("browse-list").replaceChildren(empty("Loading"));
  wholeList(mac, "/api/albums").then(
    (list) => {
      if (level() !== shown || library() !== mac) return;
      const albums = list.rows;
      if (albums.length === 0) return $("browse-list").replaceChildren(empty("Nothing here"));
      // The tiles' insets: 12 px on the left and the scrubber's strip on the right.
      const across = Math.max(2, Math.floor(($("browse-list").clientWidth - 40) / 150));
      const width = ($("browse-list").clientWidth - 40 - (across - 1) * 12) / across;
      const ids = new Map();
      const asked = new Set();
      const source = {
        total: () => Math.ceil(albums.length / across),
        row: (index) => albums.slice(index * across, index * across + across),
        need: (first, last) => {
          const missing = [];
          for (let index = first * across; index < Math.min(albums.length, (last + 2) * across); index++) {
            const id = albums[index][0];
            if (!asked.has(id)) missing.push(id);
          }
          if (missing.length === 0) return;
          for (const id of missing) asked.add(id);
          mac.json("/api/covers?albums=" + missing.join(",")).then(
            (found) => {
              for (const [album, art] of Object.entries(found)) ids.set(Number(album), art);
              grid.refresh();
            },
            (error) => say(error.message)
          );
        },
        render: (element, row) => {
          element.replaceChildren();
          const tiles = document.createElement("div");
          tiles.className = "tiles";
          for (const album of row) {
            const tile = document.createElement("button");
            tile.type = "button";
            tile.className = "tile";
            const image = document.createElement("img");
            image.alt = "";
            showCover(image, mac, ids.get(album[0]), "s");
            const title = document.createElement("div");
            title.className = "line1";
            title.textContent = album[1];
            const artist = document.createElement("div");
            artist.className = "line2";
            artist.textContent = album[2] ?? "";
            tile.append(image, title, artist);
            tile.onclick = () => enter({ kind: "albums" }, album);
            tiles.appendChild(tile);
          }
          element.appendChild(tiles);
        },
      };
      const grid = new VirtualList($("browse-list"), source, Math.ceil(width + 52), current.scroll ?? 0);
      browse.list = grid;
      scrubber(grid, (index) => albums[index * across]?.[1] ?? null);
    },
    (error) => $("browse-list").replaceChildren(empty(error.message))
  );
}

function jumpBar(names, list) {
  const bar = $("jump");
  const offsets = letterOffsets(names);
  bar.replaceChildren();
  if (offsets.length < 2) return;
  $("browse-list").classList.add("lettered");
  for (const [letter] of offsets) {
    const label = document.createElement("div");
    label.textContent = letter;
    bar.appendChild(label);
  }
  const jump = (event) => {
    event.preventDefault();
    const touch = event.touches ? event.touches[0] : event;
    const box = bar.getBoundingClientRect();
    const share = (touch.clientY - box.top) / box.height;
    const at = offsets[Math.max(0, Math.min(offsets.length - 1, Math.floor(share * offsets.length)))];
    list.scrollTo(at[1]);
  };
  bar.ontouchstart = jump;
  bar.ontouchmove = jump;
  bar.onclick = jump;
}

/// The strip on the right of Browse's list: a drag moves through the whole list in proportion,
/// slower the further left of the strip the finger goes, with the name at the top of the view
/// beside the finger. `label(index)` gives a row's name, or null while it isn't read yet.
function scrubber(list, label) {
  const strip = $("scrub");
  const bubble = $("scrub-label");
  strip.hidden = false;
  let share = 0;
  let lastY = 0;
  let pointer = null;
  const show = (y) => {
    const container = list.container;
    container.scrollTop = share * (container.scrollHeight - container.clientHeight);
    const [first] = list.visible;
    bubble.textContent = label(first) ?? (first + 1).toLocaleString() + " of " + list.source.total().toLocaleString();
    bubble.style.top = y - strip.getBoundingClientRect().top + "px";
    bubble.hidden = false;
  };
  strip.onpointerdown = (event) => {
    event.preventDefault();
    strip.setPointerCapture(event.pointerId);
    pointer = event.pointerId;
    const box = strip.getBoundingClientRect();
    share = Math.min(1, Math.max(0, (event.clientY - box.top) / box.height));
    lastY = event.clientY;
    show(event.clientY);
  };
  strip.onpointermove = (event) => {
    if (event.pointerId !== pointer) return;
    const box = strip.getBoundingClientRect();
    share = scrubbed(share, event.clientY - lastY, box.height, box.left - event.clientX);
    lastY = event.clientY;
    show(event.clientY);
  };
  strip.onpointerup = strip.onpointercancel = (event) => {
    if (event.pointerId !== pointer) return;
    pointer = null;
    bubble.hidden = true;
  };
}

const kinds = {
  artists: { kind: "artists", title: "Artists", filter: {} },
  albums: { kind: "grid", title: "Albums", filter: {} },
  genres: { kind: "genres", title: "Genres", filter: {} },
  songs: { kind: "tracks", title: "Songs", filter: { sort: "artist" } },
};

/// Browse's top, where it follows the chosen Mac again.
function chooseKind(kind) {
  const bound = libraryMac(libraryID, chosenID, "top", pairedIDs(), true);
  if (bound !== libraryID) $("results").replaceChildren();
  libraryID = bound;
  browse.kind = kind;
  for (const button of $("kinds").children) button.classList.toggle("chosen", button.dataset.kind === kind);
  browse.stack = [Object.assign({}, kinds[kind])];
  showLevel();
}

$("kinds").addEventListener("click", (event) => {
  const kind = event.target.dataset.kind;
  if (kind) chooseKind(kind);
});
$("back").addEventListener("click", () => {
  if (browse.stack.length > 1) browse.stack.pop();
  if (browse.stack.length === 1) return chooseKind(browse.kind);
  showLevel();
});
$("browse-play").addEventListener("click", () => command("playback.playTracks", "album:" + level().album, library()));
$("browse-queue").addEventListener("click", () => command("playback.queueTracks", "album:" + level().album, library()));

// MARK: Search.

const searches = new SearchQueue();
let searchTimer = 0;

function searchTyped() {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    const text = $("search").value.trim();
    if (text === "") {
      searches.typed("");
      $("results").replaceChildren();
      return;
    }
    const send = searches.typed(text);
    if (send !== null) runSearch(send);
  }, 120);
}

function runSearch(text) {
  const mac = library();
  if (!mac || !mac.paired) return;
  mac.json("/api/search?q=" + encodeURIComponent(text)).then(
    // A reply from a Mac Search no longer reads is about another library.
    (found) => searched(text, library() === mac ? found : null, mac),
    (error) => {
      searched(text, null, mac);
      say(error.message);
    }
  );
}

function searched(text, found, mac) {
  const { show, next } = searches.answered(text);
  if (show && found) showResults(found, text, mac);
  if (next !== null) runSearch(next);
}

/// Browse at Artists on `mac`'s library, where a search result was found, whichever Mac is
/// chosen.
function browseFrom(mac) {
  libraryID = mac.id;
  browse.kind = "artists";
  for (const button of $("kinds").children) button.classList.toggle("chosen", button.dataset.kind === "artists");
  browse.stack = [Object.assign({}, kinds.artists)];
  showView("browse");
}

/// Says whose library Browse and Search show when it isn't the chosen Mac's.
function renderLibraryName() {
  const mac = library();
  const text = mac && mac.id !== chosenID ? "On " + mac.name : "";
  $("library-name").textContent = text;
  $("search-library").textContent = text;
}

function showResults(found, text, mac) {
  const results = $("results");
  results.replaceChildren();
  const section = (title, rows, fill) => {
    if (rows.length === 0) return;
    const heading = document.createElement("h3");
    heading.textContent = title;
    results.appendChild(heading);
    for (const row of rows) {
      const element = document.createElement("div");
      element.className = "row";
      fill(element, row);
      results.appendChild(element);
    }
  };
  section("Artists", found.artists, (element, row) => {
    fillRow(element, { line1: row[1] });
    element.onclick = () => {
      browseFrom(mac);
      enter(level(), row);
    };
  });
  section("Albums", found.albums, (element, row) => {
    fillRow(element, { line1: row[1], line2: row[2] ?? "" });
    element.onclick = () => {
      browseFrom(mac);
      enter({ kind: "albums" }, row);
    };
  });
  section("Songs", found.tracks, (element, row) => {
    fillRow(element, {
      line1: row[1],
      line2: joined(row[2], row[3]),
      add: () => command("playback.queueTracks", "tracks:" + row[0], mac),
    });
    // The search's whole list of songs, in the order it lists them, from this one.
    element.onclick = () => command("playback.playList", playListArgument({ q: text, sort: "artist" }, row[0]), mac);
  });
  if (results.children.length === 0) results.appendChild(empty("Nothing found"));
}

$("search").addEventListener("input", searchTyped);

// MARK: Views and the strip.

function showView(name) {
  for (const view of ["now", "queue", "browse", "search"]) $("view-" + view).hidden = view !== name;
  for (const button of $("tabs").children) button.classList.toggle("chosen", button.dataset.view === name);
  if (name === "queue") queueView.reload();
  if (name === "browse" && browse.stack.length === 0) chooseKind(browse.kind);
  if (name === "browse" && browse.list) browse.list.draw();
  if (name === "now") renderNow();
}

$("tabs").addEventListener("click", (event) => {
  const view = event.target.dataset.view;
  if (view) showView(view);
});

/// Another Mac's library: what Browse, Search and Queue showed was the last one's.
function libraryChanged() {
  disposeBrowseList();
  browse.stack = [];
  browse.list = null;
  $("results").replaceChildren();
  if (!$("view-browse").hidden) chooseKind(browse.kind);
}

function renderStrip() {
  renderLibraryName();
  const strip = $("macs");
  const auto = $("auto");
  auto.hidden = picked === null;
  const buttons = [auto];
  for (const mac of macs.values()) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "mac";
    button.classList.toggle("chosen", mac.id === chosenID);
    button.classList.toggle("picked", mac.id === picked);
    const dot = document.createElement("span");
    const state = !mac.paired ? "unpaired" : mac.state ? mac.state.state : "stopped";
    dot.className = "dot " + state + (mac.paired && !mac.online ? " offline" : "");
    const name = document.createElement("span");
    name.textContent = mac.name;
    button.append(dot, name);
    button.setAttribute("aria-label", mac.name + ", " + state);
    button.onclick = () => {
      if (!mac.paired) return askToPair(mac);
      picked = mac.id;
      choose("picked");
      render();
    };
    buttons.push(button);
  }
  strip.replaceChildren(...buttons);
}

$("auto").addEventListener("click", () => {
  picked = null;
  choose("picked");
  render();
});

function render() {
  renderStrip();
  renderNow();
}

// MARK: Start, and the phone locking and unlocking.

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    for (const mac of macs.values()) mac.close();
  } else {
    for (const mac of macs.values()) {
      mac.failures = 0;
      mac.connect();
    }
    refreshInstances();
  }
});

setInterval(() => {
  if (!document.hidden) refreshInstances();
}, INSTANCES_SECONDS * 1000);

const code = /^#pair=([0-9]{6})$/.exec(location.hash);
history.replaceState(null, "", location.pathname);
if (code) {
  pairing.mac = null;
  pair(code[1]).catch((error) => {
    askToPair(null);
    $("pair-problem").textContent = error.message;
  });
} else {
  refreshInstances();
}
