# KOS TRADE — Starter / Phase 1

This is the first frontend shell and a cautious initial database schema for the KOS TRADE project.

## Files
- `index.html` — responsive Black & Gold development interface.
- `supabase/schema.sql` — initial PostgreSQL tables, RLS baseline and profile trigger.

## Run locally
1. Extract the ZIP.
2. Open `index.html` in Chrome or Edge.
3. This phase is a visual shell only. It has no live prices, login, wallet, order execution or real-money functionality.

## Publish through GitHub Pages
1. Create a new GitHub repository named `kos-trade`.
2. Upload `index.html` to the repository root.
3. Open **Settings → Pages**.
4. Under Build and deployment choose **Deploy from a branch**.
5. Select `main` and `/ (root)`, then Save.
6. Wait for GitHub Pages to publish the site.

## Supabase setup (next phase)
1. Create a new Supabase project.
2. Open SQL Editor and run `supabase/schema.sql`.
3. Keep the `service_role` key secret. Never paste it into HTML or JavaScript.
4. Configure authentication and server-side financial operations in a later phase.

## Important financial boundary
The internal engine can calculate and record simulated/internal positions, but it does not by itself execute orders in the external XAUUSD market. Do not accept customer funds or describe internal positions as live market trades. A real-money service requires appropriate legal authorization, custody/payment arrangements, market data and execution infrastructure.
