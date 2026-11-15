// Public browser configuration. The publishable key is safe to expose when RLS is enabled.
// Replace these two Supabase values after creating the separate Universe 2 project.
window.UNIVERSE2_CONFIG = Object.freeze({
  supabaseUrl: "https://YOUR_PROJECT_REF.supabase.co",
  supabasePublishableKey: "sb_publishable_REPLACE_WITH_YOUR_KEY",
  quoteWorkerUrl: "https://universe2-simulated-market.sdm3894.workers.dev",
});
