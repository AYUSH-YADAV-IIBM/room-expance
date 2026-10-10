# RoomMates — Supabase setup

## 1. Database
Run `supabase-schema.sql` in Supabase → SQL Editor. Continue only if it completes successfully. The schema includes Auth profile creation, household create/join RPCs, transactions, budgets, RLS policies, a private receipts bucket and Realtime publication.

## 2. Authentication settings
- Authentication → Sign In / Providers: Email enabled.
- Authentication → URL Configuration: Site URL should be your local Live Server origin (for this setup, `http://127.0.0.1:5500`).
- Add redirect URL `http://127.0.0.1:5500/RoomMates/**`.
- If your actual Live Server port/path changes, update these values.

## 3. Run the app and connect
1. Extract the project folder and open `RoomMates/index.html` using VS Code Live Server.
2. On the first screen, enter the Supabase Project URL and the browser-safe publishable key (or legacy anon key). Find these in Supabase Project Settings / API Keys.
3. Never enter a `service_role` key or any secret key in this browser page.
4. Create an account using Email, confirm the email if required, then sign in.
5. Create a household or join one with the invite code shared by the other roommate. Household membership is limited to two users by the provided RPC.
6. Click “Open RoomMates”. Transactions and monthly budget load from Supabase; transaction changes are subscribed through Realtime.

## Current integration scope
- Email sign-up/sign-in and sign-out.
- Create household and join household using the schema RPCs.
- Read household transactions, add expenses through `add_expense`, add contributions, save the overall monthly budget, and listen for transaction/budget changes.
- Amounts are stored in integer paise in PostgreSQL and converted to INR in the UI.

## Important limitations / test before real use
- This is an initial integration, not a security audit or production guarantee. Test RLS as each household member and as an unrelated user before using real financial records.
- The current UI still uses fixed display labels “Ayush” and “Priyatam” in the payer selector; match account display names accordingly, or update those labels for your actual profiles.
- Settlement display is a simple 50/50 calculation. Do not use it as a final payment instruction until it has been checked against your intended rules and transaction data.
- Receipt upload, settlement writes, soft-delete workflow, and full budget/reporting edge cases are not wired up yet.
- The first schema run may have partially applied statements if the SQL editor ran without a transaction and failed partway through. Confirm the complete schema succeeded before proceeding.
- Browser config is stored in localStorage on this device. The publishable/anon key is intended for browser clients, but RLS is what protects data.
