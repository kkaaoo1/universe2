const SITE_ORIGIN = "https://kkaaoo1.github.io";
const FX_SYMBOL = "USD/KRW";
const ASSETS = [
  { symbol: "V2K001", market: "KR", name: "미르에너지", currency: "KRW", exchange: "KOSPI", base: 48200, volatility: 0.008 },
  { symbol: "V2K002", market: "KR", name: "별빛바이오", currency: "KRW", exchange: "KOSDAQ", base: 31750, volatility: 0.015 },
  { symbol: "V2K003", market: "KR", name: "달무리모빌리티", currency: "KRW", exchange: "KOSPI", base: 126000, volatility: 0.011 },
  { symbol: "V2K004", market: "KR", name: "청해로보틱스", currency: "KRW", exchange: "KOSDAQ", base: 76500, volatility: 0.014 },
  { symbol: "V2K005", market: "KR", name: "온누리칩스", currency: "KRW", exchange: "KOSPI", base: 208000, volatility: 0.012 },
  { symbol: "V2K006", market: "KR", name: "새벽푸드", currency: "KRW", exchange: "KOSPI", base: 28400, volatility: 0.007 },
  { symbol: "V2K007", market: "KR", name: "파도물류", currency: "KRW", exchange: "KOSDAQ", base: 41300, volatility: 0.009 },
  { symbol: "V2K008", market: "KR", name: "나래항공", currency: "KRW", exchange: "KOSPI", base: 19200, volatility: 0.013 },
  { symbol: "V2K009", market: "KR", name: "한울건설", currency: "KRW", exchange: "KOSPI", base: 55100, volatility: 0.008 },
  { symbol: "V2K010", market: "KR", name: "자운클라우드", currency: "KRW", exchange: "KOSDAQ", base: 91700, volatility: 0.016 },
  { symbol: "V2K011", market: "KR", name: "모래시계게임즈", currency: "KRW", exchange: "KOSDAQ", base: 36200, volatility: 0.018 },
  { symbol: "V2K012", market: "KR", name: "무지개소재", currency: "KRW", exchange: "KOSPI", base: 68400, volatility: 0.01 },
  { symbol: "V2U001", market: "US", name: "Lumen Orbit", currency: "USD", exchange: "NAS", base: 84.2, volatility: 0.012 },
  { symbol: "V2U002", market: "US", name: "Northstar Bio", currency: "USD", exchange: "NAS", base: 42.75, volatility: 0.018 },
  { symbol: "V2U003", market: "US", name: "Copperfield Mobility", currency: "USD", exchange: "NYS", base: 136.4, volatility: 0.013 },
  { symbol: "V2U004", market: "US", name: "Bluehaven Robotics", currency: "USD", exchange: "NAS", base: 67.3, volatility: 0.016 },
  { symbol: "V2U005", market: "US", name: "Juniper Cloud", currency: "USD", exchange: "NAS", base: 218.6, volatility: 0.014 },
  { symbol: "V2U006", market: "US", name: "Redwood Foods", currency: "USD", exchange: "NYS", base: 31.8, volatility: 0.009 },
  { symbol: "V2U007", market: "US", name: "Tidal Freight", currency: "USD", exchange: "NYS", base: 58.55, volatility: 0.011 },
  { symbol: "V2U008", market: "US", name: "Aster Aerospace", currency: "USD", exchange: "NAS", base: 103.25, volatility: 0.017 },
  { symbol: "V2U009", market: "US", name: "Cinderstone Homes", currency: "USD", exchange: "NYS", base: 76.9, volatility: 0.01 },
  { symbol: "V2U010", market: "US", name: "Daybreak Games", currency: "USD", exchange: "NAS", base: 24.6, volatility: 0.02 },
  { symbol: "V2U011", market: "US", name: "Mosaic Materials", currency: "USD", exchange: "NYS", base: 151.7, volatility: 0.011 },
  { symbol: "V2U012", market: "US", name: "Silverline Transit", currency: "USD", exchange: "NAS", base: 45.3, volatility: 0.013 },
  { symbol: FX_SYMBOL, market: "FX", name: "가상 원·달러 환율", currency: "KRW", exchange: "FX", base: 1370, volatility: 0.0015 },
];
const BY_SYMBOL = new Map(ASSETS.map((asset) => [asset.symbol, asset]));
const SIMULATION_STEP_MS = 60_000;
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

function json(data, status = 200, cors = {}) {
  return Response.json(data, { status, headers: { ...cors, "cache-control": "no-store" } });
}

function corsFor(request) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== SITE_ORIGIN) return null;
  return {
    "access-control-allow-origin": SITE_ORIGIN,
    "access-control-allow-methods": "GET, OPTIONS",
    "access-control-allow-headers": "Accept",
    "access-control-max-age": "86400",
    "vary": "Origin",
  };
}

function randomFor(symbol, minute) {
  let value = 2166136261;
  const input = symbol + ":" + minute;
  for (let i = 0; i < input.length; i++) value = Math.imul(value ^ input.charCodeAt(i), 16777619);
  value = (value + 0x6d2b79f5) | 0;
  value = Math.imul(value ^ (value >>> 15), value | 1);
  value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
  return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
}

function newMarket(minute) {
  const day = Math.floor(minute / 1440);
  return {
    minute,
    day,
    quotes: Object.fromEntries(ASSETS.map((asset) => [asset.symbol, {
      price: asset.base,
      day_open: asset.base,
      change_pct: 0,
      as_of: new Date(minute * SIMULATION_STEP_MS).toISOString(),
    }])),
  };
}

function advanceMarket(market, targetMinute) {
  if (targetMinute <= market.minute) return market;
  const startMinute = Math.max(market.minute + 1, targetMinute - 180);
  for (let minute = startMinute; minute <= targetMinute; minute++) {
    const day = Math.floor(minute / 1440);
    for (const asset of ASSETS) {
      const quote = market.quotes[asset.symbol] || {
        price: asset.base, day_open: asset.base, change_pct: 0,
      };
      if (day !== market.day) quote.day_open = quote.price;
      const shock = (randomFor(asset.symbol, minute) * 2 - 1) * asset.volatility;
      const reversion = (asset.base / quote.price - 1) * 0.004;
      quote.price = clamp(quote.price * (1 + shock + reversion), asset.base * 0.2, asset.base * 4);
      quote.change_pct = (quote.price / quote.day_open - 1) * 100;
      quote.as_of = new Date(minute * SIMULATION_STEP_MS).toISOString();
      market.quotes[asset.symbol] = quote;
    }
    market.day = day;
  }
  market.minute = targetMinute;
  return market;
}

function toDatabaseRows(market) {
  return ASSETS.map((asset) => {
    const value = market.quotes[asset.symbol];
    return {
      symbol: asset.symbol,
      market: asset.market,
      name: asset.name,
      price: Math.round(value.price * (asset.currency === "KRW" ? 100 : 10000)) / (asset.currency === "KRW" ? 100 : 10000),
      currency: asset.currency,
      change_pct: Math.round(value.change_pct * 10000) / 10000,
      source: "SIMULATED_UNIVERSE2",
      freshness: "real_time",
      is_tradable: true,
      as_of: value.as_of,
      updated_at: new Date().toISOString(),
    };
  });
}

async function supabaseRequest(env, path, options = {}) {
  const root = String(env.SUPABASE_URL || "").replace(/\/+$/, "");
  const key = env.SUPABASE_SECRET_KEY;
  if (!root || !key) throw new Error("database_not_configured");
  return fetch(root + path, {
    ...options,
    signal: AbortSignal.timeout(8000),
    headers: {
      apikey: key,
      authorization: "Bearer " + key,
      "content-type": "application/json",
      ...options.headers,
    },
  });
}

async function publishQuotes(env, market) {
  const response = await supabaseRequest(env, "/rest/v1/market_quotes?on_conflict=symbol", {
    method: "POST",
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify(toDatabaseRows(market)),
  });
  if (!response.ok) throw new Error("quote_publish_failed_" + response.status);
}

async function settleLoans(env) {
  const response = await supabaseRequest(env, "/rest/v1/rpc/settle_campus_loans_batch", {
    method: "POST",
    body: JSON.stringify({ p_limit: 100 }),
  });
  if (!response.ok) throw new Error("loan_settlement_failed_" + response.status);
  return response.json();
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const cors = corsFor(request);
    if (url.pathname === "/health" && request.method === "GET") {
      return json({
        service: "Universe 2 fictional market",
        market: "simulated",
        update_interval_seconds: 60,
        runs_every_day: true,
        configured: Boolean(env.SUPABASE_URL && env.SUPABASE_SECRET_KEY),
        asset_count: ASSETS.length - 1,
      });
    }
    if (!cors) return json({ error: "origin_not_allowed" }, 403);
    if (request.method === "OPTIONS" && ["/quote", "/overview"].includes(url.pathname)) {
      return new Response(null, { status: 204, headers: cors });
    }
    if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405, cors);

    const id = env.SIMULATION_MARKET.idFromName("universe2");
    const marketStub = env.SIMULATION_MARKET.get(id);
    if (url.pathname === "/quote") {
      const symbol = String(url.searchParams.get("symbol") || "").trim().toUpperCase();
      const asset = BY_SYMBOL.get(symbol);
      if (!asset || asset.market === "FX") return json({ error: "unknown_virtual_stock" }, 404, cors);
      try {
        const response = await marketStub.fetch("https://market.internal/tick");
        if (!response.ok) throw new Error("market_unavailable");
        const data = await response.json();
        const quote = data.quotes.find((item) => item.symbol === symbol);
        return json(quote, 200, cors);
      } catch {
        return json({ error: "virtual_market_temporarily_unavailable" }, 503, cors);
      }
    }
    if (url.pathname === "/overview") {
      try {
        const tick = await marketStub.fetch("https://market.internal/tick");
        if (!tick.ok) throw new Error("market_unavailable");
        const response = await supabaseRequest(env, "/rest/v1/rpc/get_campus_league_overview", {
          method: "POST",
          body: "{}",
        });
        if (!response.ok) throw new Error("overview_unavailable");
        return json(await response.json(), 200, cors);
      } catch {
        return json({ error: "universe2_backend_not_ready" }, 503, cors);
      }
    }
    return json({ error: "not_found" }, 404, cors);
  },

  async scheduled(_controller, env, ctx) {
    const id = env.SIMULATION_MARKET.idFromName("universe2");
    const marketStub = env.SIMULATION_MARKET.get(id);
    ctx.waitUntil(Promise.all([
      marketStub.fetch("https://market.internal/tick").then((response) => {
        if (!response.ok) throw new Error("market_tick_failed");
      }),
      settleLoans(env),
    ]).catch((error) => console.error("scheduled_job_failed", error?.message || "Error")));
  },
};

export class SimulationMarket {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/status") {
      const market = await this.state.storage.get("market");
      return json({ updated_at: market ? new Date(market.minute * SIMULATION_STEP_MS).toISOString() : null });
    }
    if (url.pathname !== "/tick") return new Response("Not found", { status: 404 });
    const minute = Math.floor(Date.now() / SIMULATION_STEP_MS);
    let market = await this.state.storage.get("market");
    if (!market) market = newMarket(minute);
    else market = advanceMarket(market, minute);
    await this.state.storage.put("market", market);

    const publishedMinute = await this.state.storage.get("published-minute");
    if (publishedMinute !== market.minute) {
      await publishQuotes(this.env, market);
      await this.state.storage.put("published-minute", market.minute);
    }
    return json({ updated_at: new Date(market.minute * SIMULATION_STEP_MS).toISOString(), quotes: toDatabaseRows(market) });
  }
}
