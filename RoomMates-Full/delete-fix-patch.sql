-- RoomMates soft-delete fix
-- Run in Supabase SQL Editor. This keeps the row for audit/history but hides it
-- from the app because its transaction query filters deleted_at IS NULL.

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;

ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Household members can soft-delete transactions" ON public.transactions;

CREATE POLICY "Household members can soft-delete transactions"
ON public.transactions
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.household_members hm
    WHERE hm.household_id = transactions.household_id
      AND hm.user_id = auth.uid()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.household_members hm
    WHERE hm.household_id = transactions.household_id
      AND hm.user_id = auth.uid()
  )
);
