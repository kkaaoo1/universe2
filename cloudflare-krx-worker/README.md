# Universe 2 simulated market Worker

This Worker serves 24 fictional stock quotes and a fictional USD/KRW rate. It uses a Cloudflare Durable Object to keep one shared random-walk state and a once-per-minute Cron Trigger. There are no market hours; the schedule also runs on weekends and holidays.

## Deploy from Git

1. Connect a new Cloudflare Worker to kkaaoo1/universe2.
2. Use cloudflare-krx-worker as the root directory and npx wrangler deploy as the deploy command.
3. Configure SUPABASE_URL as a variable and SUPABASE_SECRET_KEY as a secret in this Worker. Both must belong to the separate Universe 2 Supabase project.
4. Check https://universe2-simulated-market.sdm3894.workers.dev/health. It should report configured: true and asset_count: 24.

The Cron Trigger advances the market and calls settle_campus_loans_batch once each minute. Quote rows use SIMULATED_UNIVERSE2 as their source and remain tradable for two minutes. A quote request also advances and publishes the current shared snapshot if the scheduled call was delayed.

The Worker does not contain or request KIS credentials. It must use a separate Supabase project so synthetic quotes and player data cannot enter the original league.
