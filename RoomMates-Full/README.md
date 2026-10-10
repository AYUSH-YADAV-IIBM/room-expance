# RoomMates

A responsive shared-living expense tracker for two roommates, with a Supabase-backed initial integration.

## Files
- `index.html` — browser UI, Supabase connection screen, email auth, household create/join, shared transactions and budget sync.
- `supabase-schema.sql` — PostgreSQL schema and RLS/RPC foundation.
- `SUPABASE_SETUP.md` — configuration, run steps and limitations.

## Run
Open `index.html` with VS Code Live Server. In the app, enter your Supabase Project URL and browser-safe publishable/anon key, then create/sign in to an account and create/join a household.

Read `SUPABASE_SETUP.md` before using. Do not put service-role or secret keys in the browser. Test RLS and data flows before recording real expenses.
