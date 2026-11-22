import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!url || !anonKey || !serviceKey || !token) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const authClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  if (authError || !authData.user) {
    return new Response(JSON.stringify({ error: "Sessioni nuk është valide." }), {
      status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const response = await fetch("https://api.gold-api.com/price/XAU", {
      headers: { "Accept": "application/json", "Cache-Control": "no-cache" },
    });
    if (!response.ok) throw new Error("Burimi i çmimit nuk u përgjigj.");
    const quote = await response.json();
    const price = Number(quote.price);
    const providerTime = new Date(quote.updatedAt);
    const ageSeconds = (Date.now() - providerTime.getTime()) / 1000;

    if (!Number.isFinite(price) || price < 1000 || price > 10000 ||
        !Number.isFinite(providerTime.getTime()) || ageSeconds > 90 || ageSeconds < -30) {
      throw new Error("Kuota XAUUSD është e pavlefshme ose e vjetruar.");
    }

    const db = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const stamp = providerTime.toISOString();
    const quoteRow = {
      symbol: "XAUUSD",
      price,
      source: "Gold API · XAU spot",
      provider_updated_at: stamp,
      received_at: new Date().toISOString(),
    };
    const { error: quoteError } = await db.from("market_quotes").upsert(quoteRow, { onConflict: "symbol" });
    if (quoteError) throw quoteError;

    const { error: tickError } = await db.from("market_ticks").upsert({
      ...quoteRow,
    }, { onConflict: "symbol,provider_updated_at", ignoreDuplicates: true });
    if (tickError) throw tickError;

    return new Response(JSON.stringify({
      symbol: "XAUUSD",
      price,
      source: "Gold API · XAU spot",
      updatedAt: stamp,
      ageSeconds: Math.max(0, Math.round(ageSeconds)),
    }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message || "Market feed error" }), {
      status: 503,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
