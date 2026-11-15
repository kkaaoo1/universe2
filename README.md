# Universe 2

Universe 2 is a separate copy of the Campus League game. It uses 24 fictional Korean and US companies. A Cloudflare Durable Object changes their shared prices once per minute, every day of the year, including weekends and holidays. It does not call KIS or any real-market price API.

The online game uses its own Supabase project so its users, balances, trades, loans, and rankings stay separate from `universe`.

## Site

After GitHub Pages is enabled for GitHub Actions, the site URL is:

https://kkaaoo1.github.io/universe2/

GitHub Pages is configured to use the GitHub Actions source. The Pages workflow publishes the repository root on every push to `main`.

## One-time setup

1. Create a separate Supabase project for Universe 2. In its SQL Editor, run the full `campus_league_setup.sql` file once.
2. Enable Kakao in **Authentication → Sign In / Providers**. Use your Kakao REST API key as Client ID and the Kakao Client Secret as Client Secret. Add the new Supabase callback URL (`https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback`) to the Kakao app's Redirect URI list; keep the callback used by the original site.
3. In Supabase **Authentication → URL Configuration**, set the Site URL and Redirect URL to `https://kkaaoo1.github.io/universe2/`.
4. Edit `config.js` with the new project's URL and publishable key. The publishable key is designed for browser use; never place a Supabase secret key in this file.
5. Connect a new Cloudflare Worker to this repository. Set its root directory to `cloudflare-krx-worker` and its deploy command to `npx wrangler deploy`. The Worker name is `universe2-simulated-market`.
6. In the new Worker settings, add `SUPABASE_URL` as a variable and `SUPABASE_SECRET_KEY` as a secret. Use the new Universe 2 project values. Do not change the existing `campus-league-krx-feed` Worker.
7. After Pages and the Worker deploy, open the Pages site and sign in with Kakao. Worker `/health` should report `configured: true` and `asset_count: 24`.

This setup intentionally keeps the new league's data separate. Until the new Supabase project and Worker secrets are configured, the public page shows a setup notice and trading stays unavailable.

## Game rules

- Every player starts with ₩10,000,000 of virtual money.
- Korean-market fictional stocks trade in KRW. US-market fictional stocks trade in USD after in-game exchange.
- Prices move by a bounded random walk once per minute, including Saturdays, Sundays, and holidays. This is a simulation, not a forecast or investment data.
- Loans accrue at an annual 8% rate and are charged monthly in KRW. Bankruptcy and loan restrictions match the original game.
- The season is kept open through 2099 so the daily market and game remain available without a yearly market-hours calendar.
- No real security orders, payments, or currency conversions take place.
