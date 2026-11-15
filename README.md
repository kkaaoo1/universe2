# Universe 2

Universe 2 is a separate copy of the Campus League game. It uses 24 fictional Korean and US companies. A Cloudflare Durable Object changes their shared prices once per minute, every day of the year, including weekends and holidays. It does not call KIS or any real-market price API.

The online game uses its own Supabase project so its users, balances, trades, loans, and rankings stay separate from `universe`.

## Site

After GitHub Pages is enabled for GitHub Actions, the site URL is:

https://kkaaoo1.github.io/universe2/

GitHub Pages is configured to use the GitHub Actions source. The Pages workflow publishes the repository root on every push to `main`.

## One-time setup

1. In the separate Universe 2 Supabase project, run `campus_league_setup.sql` once in SQL Editor.
2. In Kakao Developers, keep Kakao Login ON and add this Redirect URI to the REST API key's Kakao Login settings: `https://wcqgacolikxuhquhplyu.supabase.co/auth/v1/callback`. Use the REST API key for Supabase's Kakao Client ID and the Kakao Login Client Secret for Client Secret; do not use the Native App key.
3. Request only the Kakao `profile_nickname` scope. Do not request `account_email` or `profile_image`. In Supabase **Authentication → Providers → Kakao**, enable Kakao, enter those two credentials, and enable **Allow users without an email**.
4. In Supabase **Authentication → URL Configuration**, set Site URL to `https://kkaaoo1.github.io/universe2/` and add that URL to the allowed Redirect URLs.
5. `config.js` already contains this project's URL and browser-safe publishable key. Never put a Supabase secret key in `config.js` or any other browser code.
6. The fictional market Worker is `universe2-simulated-market` at `https://universe2-simulated-market.sdm3894.workers.dev`. Its `SUPABASE_URL` is already configured. In Cloudflare **Workers & Pages → universe2-simulated-market → Settings → Variables and Secrets**, add `SUPABASE_SECRET_KEY` as a **Secret** using the new project's `sb_secret_...` key, then deploy the setting. Do not change the existing `campus-league-krx-feed` Worker.
7. Open `https://universe2-simulated-market.sdm3894.workers.dev/health`. It should report `configured: true` and `asset_count: 24` after the secret is saved. Then use the Pages site and sign in with Kakao.

This setup intentionally keeps the new league's data separate. Until the Kakao provider and Worker secret are configured, the public page may show a setup notice and online trading stays unavailable.

## Game rules

- Every player starts with ₩10,000,000 of virtual money.
- Korean-market fictional stocks trade in KRW. US-market fictional stocks trade in USD after in-game exchange.
- Prices move by a bounded random walk once per minute, including Saturdays, Sundays, and holidays. This is a simulation, not a forecast or investment data.
- Loans accrue at an annual 8% rate and are charged monthly in KRW. Bankruptcy and loan restrictions match the original game.
- The season is kept open through 2099 so the daily market and game remain available without a yearly market-hours calendar.
- No real security orders, payments, or currency conversions take place.
