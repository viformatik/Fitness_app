import { createClient } from "npm:@supabase/supabase-js@2";

// Public, read-only proxy to Open Food Facts Search-a-licious.
// No user token, diary data or secret is sent upstream. The descriptive
// User-Agent and a shared quota respect the upstream API conditions.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};
const reply = (status: number, body: unknown, cache = "no-store") =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": cache },
  });

const text = (value: unknown): string => {
  if (typeof value === "string") return value.trim().slice(0, 180);
  if (Array.isArray(value)) return value.map(text).find(Boolean) ?? "";
  return "";
};
const nutrient = (row: Record<string, unknown>, key: string): number | null => {
  const value = row[key];
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100000
    ? Math.round(value * 10000) / 10000
    : null;
};
const macro = (row: Record<string, unknown>, key: string): number | null => {
  const value = nutrient(row, `${key}_100g`);
  return value !== null && value <= 1000 ? value : null;
};
const put = (out: Record<string, number>, key: string, value: number | null) => {
  if (value !== null) out[key] = value;
};

export function cleanHit(raw: unknown): Record<string, unknown> | null {
  if (!raw || typeof raw !== "object") return null;
  const hit = raw as Record<string, unknown>;
  const n = (hit.nutriments && typeof hit.nutriments === "object")
    ? hit.nutriments as Record<string, unknown>
    : {};
  const calories = macro(n, "energy-kcal");
  const protein = macro(n, "proteins");
  const fat = macro(n, "fat");
  const carbs = macro(n, "carbohydrates");
  // Missing macros are not zero: exclude incomplete products rather than guess.
  if ([calories, protein, fat, carbs].some((v) => v === null)) return null;
  const name = text(hit.product_name_ru) || text(hit.product_name) || text(hit.generic_name);
  if (name.length < 2) return null;
  const micros: Record<string, number> = {};
  put(micros, "fiber", nutrient(n, "fiber_100g"));
  put(micros, "sugars", nutrient(n, "sugars_100g"));
  put(micros, "saturatedFat", nutrient(n, "saturated-fat_100g"));
  const mono = nutrient(n, "monounsaturated-fat_100g");
  const poly = nutrient(n, "polyunsaturated-fat_100g");
  put(micros, "unsaturatedFat", mono !== null && poly !== null ? mono + poly : null);
  const sodium = nutrient(n, "sodium_100g");
  const salt = nutrient(n, "salt_100g");
  put(micros, "sodium", sodium !== null ? sodium * 1000 : salt !== null ? salt * 400 : null);
  const simple: Array<[string, string]> = [
    ["potassium", "potassium_100g"], ["iron", "iron_100g"], ["calcium", "calcium_100g"],
    ["magnesium", "magnesium_100g"], ["zinc", "zinc_100g"], ["selenium", "selenium_100g"],
    ["vitaminA", "vitamin-a_100g"], ["vitaminC", "vitamin-c_100g"],
    ["vitaminD", "vitamin-d_100g"], ["vitaminE", "vitamin-e_100g"],
    ["vitaminK", "vitamin-k_100g"], ["thiamin", "thiamin_100g"],
    ["riboflavin", "riboflavin_100g"], ["niacin", "niacin_100g"],
    ["vitaminB6", "vitamin-b6_100g"], ["folate", "folate_100g"],
    ["vitaminB12", "vitamin-b12_100g"],
  ];
  for (const [key, field] of simple) put(micros, key, nutrient(n, field));
  const tags = Array.isArray(hit.categories_tags) ? hit.categories_tags : [];
  const category = text(tags[0]).replace(/^[a-z]{2}:/, "").replaceAll("-", " ");
  const code = text(hit.code);
  return {
    name,
    calories,
    protein,
    fat,
    carbs,
    micros,
    category: category || "Упакованные продукты",
    brand: text(hit.brands) || null,
    barcode: /^\d{8,14}$/.test(code) ? code : null,
  };
}

async function hashClient(req: Request): Promise<string> {
  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const ip = forwarded || req.headers.get("x-real-ip") || "unknown-client";
  const salt = Deno.env.get("FOOD_SEARCH_HASH_SALT") || Deno.env.get("SUPABASE_URL") || "fitness-smart";
  const bytes = new TextEncoder().encode(`${salt}|${ip}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "GET") return reply(405, { error: "GET required" });
  let url: URL;
  try {
    url = new URL(req.url);
  } catch {
    return reply(400, { error: "Invalid request" });
  }
  // Remove Lucene operators and punctuation that could change the upstream query.
  const query = (url.searchParams.get("q") ?? "")
    .normalize("NFKC")
    .replace(/[^\p{L}\p{N}\s'.-]/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80);
  if (query.length < 2) return reply(400, { error: "Query must be 2–80 characters" });
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publicKey = Deno.env.get("APP_PUBLIC_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !publicKey) return reply(503, { error: "Catalog proxy is not configured" });
  try {
    const keyHash = await hashClient(req);
    const supabase = createClient(supabaseUrl, publicKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: allowed, error: quotaError } = await supabase.rpc(
      "reserve_fitness_food_search_call",
      { p_key: keyHash },
    );
    if (quotaError || allowed !== true) {
      return reply(429, { error: "Shared search limit reached. Try again in a minute." });
    }
    const upstream = new URL("https://search.openfoodfacts.org/search");
    upstream.searchParams.set("q", query);
    upstream.searchParams.set("langs", "ru,en");
    upstream.searchParams.set("page_size", "25");
    upstream.searchParams.set(
      "fields",
      "code,product_name,product_name_ru,generic_name,brands,categories_tags,nutriments",
    );
    const response = await fetch(upstream, {
      headers: {
        "Accept": "application/json",
        "User-Agent": "FitnessSmart/2.3 (https://fitness-smart-navy.vercel.app; public nutrition catalog)",
      },
      signal: AbortSignal.timeout(15000),
    });
    if (response.status === 429 || response.status === 503) {
      return reply(429, { error: "Open Food Facts is busy. Try again in a minute." });
    }
    if (!response.ok) return reply(502, { error: "Product catalog is temporarily unavailable" });
    const data = await response.json();
    const hits = data && typeof data === "object" && Array.isArray(data.hits) ? data.hits : [];
    const items = hits.map(cleanHit).filter((item: unknown) => item !== null).slice(0, 25);
    return reply(200, {
      items,
      source: "Open Food Facts",
      license: "ODbL",
      attribution: "© Open Food Facts contributors — openfoodfacts.org, ODbL",
      note: "Values are per 100 g and may be incomplete; check the package.",
    }, "public, max-age=300");
  } catch (_) {
    return reply(502, { error: "Product catalog request failed or timed out. Offline catalog is still available." });
  }
});
