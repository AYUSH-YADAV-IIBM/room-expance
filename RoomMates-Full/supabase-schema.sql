-- RoomMates schema. All money is stored as integer paise (bigint). No floats.

create extension if not exists pgcrypto;



create table profiles (

  id uuid primary key references auth.users(id) on delete cascade,

  display_name text not null check (length(trim(display_name)) > 0),

  avatar_url text,

  created_at timestamptz not null default now(),

  updated_at timestamptz not null default now()

);



create table households (

  id uuid primary key default gen_random_uuid(),

  name text not null,

  invite_code text not null unique default encode(gen_random_bytes(6), 'hex'),

  opening_fund_paise bigint not null default 0 check (opening_fund_paise >= 0),

  timezone text not null default 'Asia/Kolkata',

  created_by uuid not null references profiles(id),

  created_at timestamptz not null default now()

);



create table household_members (

  household_id uuid not null references households(id) on delete cascade,

  user_id uuid not null references profiles(id) on delete cascade,

  role text not null default 'member' check (role in ('owner','member')),

  joined_at timestamptz not null default now(),

  primary key (household_id, user_id)

);

create unique index one_household_per_user on household_members(user_id);



create table transactions (

  id uuid primary key default gen_random_uuid(),

  household_id uuid not null references households(id) on delete cascade,

  created_by uuid not null references profiles(id),

  created_by_name text not null,

  payer_id uuid references profiles(id),            -- who paid / contributed

  transaction_type text not null check (transaction_type in ('expense','contribution')),

  expense_type text check (expense_type in ('shared','personal')),

  payment_source text check (payment_source in ('personal','fund')),

  title text not null,

  description text,

  notes text,

  amount_paise bigint not null check (amount_paise > 0),

  category text,

  transaction_date timestamptz not null default now(),

  payment_method text not null default 'upi' check (payment_method in ('cash','upi','bank_transfer','other')),

  receipt_path text,

  deleted_at timestamptz,

  deleted_by uuid references profiles(id),

  created_at timestamptz not null default now(),

  updated_at timestamptz not null default now(),

  -- contributions are never expenses; expenses always carry type/source/category

  constraint contribution_shape check (

    transaction_type <> 'contribution'

    or (expense_type is null and payment_source is null and payer_id is not null)),

  constraint expense_shape check (

    transaction_type <> 'expense'

    or (expense_type is not null and payment_source is not null and payer_id is not null and category is not null)),

  -- personal expenses are never paid from the shared fund

  constraint personal_not_from_fund check (not (expense_type = 'personal' and payment_source = 'fund'))

);

create index tx_household_date on transactions(household_id, transaction_date desc) where deleted_at is null;

create index tx_household_type on transactions(household_id, transaction_type, expense_type) where deleted_at is null;



create table expense_splits (

  transaction_id uuid not null references transactions(id) on delete cascade,

  user_id uuid not null references profiles(id),

  share_paise bigint not null check (share_paise >= 0),

  primary key (transaction_id, user_id)

);



create table settlements (

  id uuid primary key default gen_random_uuid(),

  household_id uuid not null references households(id) on delete cascade,

  from_user uuid not null references profiles(id),

  to_user uuid not null references profiles(id),

  amount_paise bigint not null check (amount_paise > 0),

  method text not null default 'upi' check (method in ('cash','upi','bank_transfer','other')),

  note text,

  settled_at timestamptz not null default now(),

  created_by uuid not null references profiles(id),

  deleted_at timestamptz,

  check (from_user <> to_user)

);



create table recurring_bills (

  id uuid primary key default gen_random_uuid(),

  household_id uuid not null references households(id) on delete cascade,

  title text not null,

  category text not null,

  expected_amount_paise bigint check (expected_amount_paise > 0), -- null = varies (electricity)

  frequency text not null check (frequency in ('weekly','monthly','quarterly','yearly')),

  due_day int check (due_day between 1 and 31),

  active boolean not null default true,

  created_by uuid not null references profiles(id),

  created_at timestamptz not null default now()

);



-- One row per occurrence; payment is only linked after a user confirms it.

create table bill_occurrences (

  id uuid primary key default gen_random_uuid(),

  bill_id uuid not null references recurring_bills(id) on delete cascade,

  household_id uuid not null references households(id) on delete cascade,

  due_date date not null,

  transaction_id uuid references transactions(id),

  unique (bill_id, due_date)

);



create table budgets (

  id uuid primary key default gen_random_uuid(),

  household_id uuid not null references households(id) on delete cascade,

  month date not null,                    -- first day of month

  category text,                          -- null = overall budget

  limit_paise bigint not null check (limit_paise > 0)

);

create unique index budgets_unique on budgets(household_id, month, coalesce(category,''));



create table notifications (

  id uuid primary key default gen_random_uuid(),

  household_id uuid not null references households(id) on delete cascade,

  recipient_id uuid not null references profiles(id) on delete cascade,

  kind text not null,

  message text not null,

  read_at timestamptz,

  created_at timestamptz not null default now()

);



create table audit_logs (

  id bigint generated always as identity primary key,

  household_id uuid not null,

  actor_id uuid,

  table_name text not null,

  record_id uuid,

  action text not null,

  old_data jsonb,

  new_data jsonb,

  created_at timestamptz not null default now()

);



-- ---------- helpers ----------

create or replace function is_member(h uuid) returns boolean

language sql stable security definer set search_path = public as $$

  select exists (select 1 from household_members where household_id = h and user_id = auth.uid());

$$;



create or replace function touch_updated_at() returns trigger language plpgsql as $$

begin new.updated_at = now(); return new; end $$;

create trigger tx_touch before update on transactions for each row execute function touch_updated_at();



-- Server-side attribution: client cannot forge created_by / display name.

create or replace function stamp_transaction() returns trigger

language plpgsql security definer set search_path = public as $$

begin

  if tg_op = 'INSERT' then

    new.created_by := auth.uid();

    select display_name into new.created_by_name from profiles where id = auth.uid();

  else

    new.created_by := old.created_by;

    new.created_by_name := old.created_by_name;

    new.household_id := old.household_id;

  end if;

  if new.payer_id is not null and not exists

     (select 1 from household_members where household_id = new.household_id and user_id = new.payer_id) then

    raise exception 'payer is not a household member';

  end if;

  return new;

end $$;

create trigger tx_stamp before insert or update on transactions for each row execute function stamp_transaction();



-- Splits must sum exactly to the expense amount (checked at commit).

create or replace function check_splits() returns trigger

language plpgsql as $$

declare t record; s bigint;

begin

  select * into t from transactions where id = coalesce(new.transaction_id, old.transaction_id);

  if t.id is null or t.deleted_at is not null then return null; end if;

  if t.transaction_type = 'expense' and t.expense_type = 'shared' then

    select coalesce(sum(share_paise),0) into s from expense_splits where transaction_id = t.id;

    if s <> t.amount_paise then

      raise exception 'splits (%) must equal amount (%)', s, t.amount_paise;

    end if;

  end if;

  return null;

end $$;

create constraint trigger splits_sum after insert or update or delete on expense_splits

  deferrable initially deferred for each row execute function check_splits();



-- Audit log

create or replace function audit() returns trigger

language plpgsql security definer set search_path = public as $$

declare r jsonb; h uuid;

begin

  r := to_jsonb(coalesce(new, old));

  h := (r->>'household_id')::uuid;

  insert into audit_logs(household_id, actor_id, table_name, record_id, action, old_data, new_data)

  values (h, auth.uid(), tg_table_name, (r->>'id')::uuid, tg_op,

          case when tg_op <> 'INSERT' then to_jsonb(old) end,

          case when tg_op <> 'DELETE' then to_jsonb(new) end);

  return null;

end $$;

create trigger audit_tx after insert or update or delete on transactions for each row execute function audit();

create trigger audit_settle after insert or update or delete on settlements for each row execute function audit();

create trigger audit_budget after insert or update or delete on budgets for each row execute function audit();



-- Profile auto-creation on signup

create or replace function handle_new_user() returns trigger

language plpgsql security definer set search_path = public as $$

begin

  insert into profiles(id, display_name)

  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1)));

  return new;

end $$;

create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();



-- Household creation / joining via invite code (max 2 members)

create or replace function create_household(p_name text, p_opening bigint default 0) returns uuid

language plpgsql security definer set search_path = public as $$

declare h uuid;

begin

  if auth.uid() is null then raise exception 'not authenticated'; end if;

  insert into households(name, opening_fund_paise, created_by) values (p_name, p_opening, auth.uid()) returning id into h;

  insert into household_members(household_id, user_id, role) values (h, auth.uid(), 'owner');

  return h;

end $$;



create or replace function join_household(p_code text) returns uuid

language plpgsql security definer set search_path = public as $$

declare h uuid;

begin

  if auth.uid() is null then raise exception 'not authenticated'; end if;

  select id into h from households where invite_code = p_code;

  if h is null then raise exception 'invalid invite code'; end if;

  if (select count(*) from household_members where household_id = h) >= 2 then

    raise exception 'household is full'; end if;

  insert into household_members(household_id, user_id) values (h, auth.uid());

  return h;

end $$;



-- Atomic expense creation: transaction row + splits in one DB transaction.

create or replace function add_expense(

  p_household uuid, p_title text, p_amount bigint, p_category text, p_payer uuid,

  p_type text, p_source text, p_method text, p_date timestamptz,

  p_description text, p_notes text, p_receipt text, p_splits jsonb  -- [{"user_id":..., "share_paise":...}]

) returns uuid

language plpgsql security invoker set search_path = public as $$

declare id uuid;

begin

  insert into transactions(household_id, transaction_type, expense_type, payment_source, title, amount_paise,

    category, payer_id, payment_method, transaction_date, description, notes, receipt_path, created_by, created_by_name)

  values (p_household,'expense',p_type,p_source,p_title,p_amount,p_category,p_payer,p_method,

    coalesce(p_date,now()),p_description,p_notes,p_receipt, auth.uid(), '') returning transactions.id into id;

  if p_type = 'shared' then

    insert into expense_splits(transaction_id, user_id, share_paise)

    select id, (e->>'user_id')::uuid, (e->>'share_paise')::bigint from jsonb_array_elements(p_splits) e;

  end if;

  return id;

end $$;



-- ---------- Row Level Security ----------

alter table profiles enable row level security;

alter table households enable row level security;

alter table household_members enable row level security;

alter table transactions enable row level security;

alter table expense_splits enable row level security;

alter table settlements enable row level security;

alter table recurring_bills enable row level security;

alter table bill_occurrences enable row level security;

alter table budgets enable row level security;

alter table notifications enable row level security;

alter table audit_logs enable row level security;



create policy profiles_read on profiles for select using (

  id = auth.uid() or exists (select 1 from household_members a join household_members b

    on a.household_id = b.household_id where a.user_id = auth.uid() and b.user_id = profiles.id));

create policy profiles_update on profiles for update using (id = auth.uid()) with check (id = auth.uid());



create policy hh_read on households for select using (is_member(id));

create policy hh_update on households for update using (is_member(id)) with check (is_member(id));

create policy members_read on household_members for select using (is_member(household_id));



create policy tx_read on transactions for select using (is_member(household_id));

create policy tx_insert on transactions for insert with check (is_member(household_id) and created_by = auth.uid());

-- Only the creator may edit / soft-delete their own entries.

create policy tx_update on transactions for update using (is_member(household_id) and created_by = auth.uid())

  with check (is_member(household_id) and created_by = auth.uid());

-- no DELETE policy: hard deletes are blocked; use deleted_at.



create policy splits_read on expense_splits for select using (

  exists (select 1 from transactions t where t.id = transaction_id and is_member(t.household_id)));

create policy splits_write on expense_splits for all using (

  exists (select 1 from transactions t where t.id = transaction_id and t.created_by = auth.uid()))

  with check (exists (select 1 from transactions t where t.id = transaction_id and t.created_by = auth.uid()));



create policy settle_read on settlements for select using (is_member(household_id));

create policy settle_insert on settlements for insert with check (

  is_member(household_id) and created_by = auth.uid()

  and exists (select 1 from household_members where household_id = settlements.household_id and user_id = from_user)

  and exists (select 1 from household_members where household_id = settlements.household_id and user_id = to_user));

create policy settle_update on settlements for update using (created_by = auth.uid()) with check (created_by = auth.uid());



create policy bills_all on recurring_bills for all using (is_member(household_id)) with check (is_member(household_id));

create policy occ_all on bill_occurrences for all using (is_member(household_id)) with check (is_member(household_id));

create policy budgets_all on budgets for all using (is_member(household_id)) with check (is_member(household_id));

create policy notif_read on notifications for select using (recipient_id = auth.uid() and is_member(household_id));

create policy notif_update on notifications for update using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

create policy audit_read on audit_logs for select using (is_member(household_id));



-- ---------- Storage: private receipts, path = <household_id>/<file> ----------

insert into storage.buckets(id, name, public) values ('receipts','receipts',false) on conflict do nothing;

create policy receipts_read on storage.objects for select using (

  bucket_id = 'receipts' and is_member(((storage.foldername(name))[1])::uuid));

create policy receipts_insert on storage.objects for insert with check (

  bucket_id = 'receipts' and is_member(((storage.foldername(name))[1])::uuid));



-- Realtime

alter publication supabase_realtime add table transactions, settlements, notifications;
