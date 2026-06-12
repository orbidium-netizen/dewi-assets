-- ============================================================
-- DEWI ASSETS — Schema v2: Full Inventory Model
-- Run AFTER dewi-assets-schema.sql (which creates admin_accounts,
-- board_schools, admin_invites, and the SECURITY DEFINER helpers).
--
-- This adds:
--   1. school_items — admin-created tagged/serialized inventory
--   2. consumables — stock-level tracking (paper towel, toner, etc.)
--   3. stock_log — consumable movement history
--
-- VISIBILITY MODEL:
--   Tech items (school_items.visibility = 'board') → school + board
--   Non-tech items (school_items.visibility = 'school') → school only
--   Consumables → school only, always. Board never sees these.
--
-- Run in Supabase SQL Editor (Console UI, not CLI).
-- ============================================================

-- ─────────────────────────────────────────────
-- 1. school_items — Admin-created inventory
-- ─────────────────────────────────────────────

create table if not exists school_items (
  id              uuid primary key default gen_random_uuid(),
  school          text not null,
  created_by      uuid references auth.users(id),

  -- Identity
  item_name       text not null,
  description     text,
  category        text not null default 'equipment'
                  check (category in ('tech', 'equipment', 'furniture', 'instruments', 'supplies', 'other')),

  -- Visibility: 'board' = school + board, 'school' = school only
  -- Default is set by the frontend based on category:
  --   category='tech' → visibility='board'
  --   everything else → visibility='school'
  visibility      text not null default 'school'
                  check (visibility in ('school', 'board')),

  -- Identification
  serial_number   text,
  tag_id          text unique,

  -- Details
  manufacturer    text,
  model           text,
  location        text,
  purchase_year   int,
  purchase_cost   numeric(10,2),
  condition       text default 'good'
                  check (condition in ('excellent', 'good', 'fair', 'poor', 'damaged', 'lost', 'retired')),
  quantity        int default 1,

  -- Metadata
  notes           jsonb default '{}'::jsonb,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

alter table school_items enable row level security;

-- School admins: see everything at their school
-- Board admins: see only board-visibility items across their schools
drop policy if exists "school_items_select" on school_items;
create policy "school_items_select" on school_items
  for select using (
    (admin_role() = 'school' and school = admin_school())
    or (admin_role() = 'board' and visibility = 'board'
        and school in (select admin_school_names()))
  );

drop policy if exists "school_items_insert" on school_items;
create policy "school_items_insert" on school_items
  for insert with check (school = admin_school());

drop policy if exists "school_items_update" on school_items;
create policy "school_items_update" on school_items
  for update using (school = admin_school());

drop policy if exists "school_items_delete" on school_items;
create policy "school_items_delete" on school_items
  for delete using (school = admin_school());

-- Index for common queries
create index if not exists idx_school_items_school on school_items(school);
create index if not exists idx_school_items_category on school_items(category);
create index if not exists idx_school_items_tag_id on school_items(tag_id);
create index if not exists idx_school_items_visibility on school_items(visibility, school);


-- ─────────────────────────────────────────────
-- 2. consumables — Stock-level tracking
-- ─────────────────────────────────────────────

create table if not exists consumables (
  id                uuid primary key default gen_random_uuid(),
  school            text not null,
  created_by        uuid references auth.users(id),

  -- Identity
  item_name         text not null,
  description       text,
  category          text default 'other'
                    check (category in ('paper', 'cleaning', 'ink_toner', 'classroom', 'bathroom', 'other')),

  -- Stock tracking
  unit              text not null default 'case',
  current_stock     int not null default 0,
  reorder_threshold int default 5,
  reorder_quantity  int,

  -- Purchasing
  supplier          text,
  unit_cost         numeric(10,2),

  -- Location / responsibility
  location          text,
  managed_by        text,

  -- Metadata
  last_restocked    timestamptz,
  notes             jsonb default '{}'::jsonb,
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

alter table consumables enable row level security;

-- Consumables: ALWAYS school-only. Board admins get zero rows.
drop policy if exists "consumables_select" on consumables;
create policy "consumables_select" on consumables
  for select using (admin_role() = 'school' and school = admin_school());

drop policy if exists "consumables_insert" on consumables;
create policy "consumables_insert" on consumables
  for insert with check (school = admin_school());

drop policy if exists "consumables_update" on consumables;
create policy "consumables_update" on consumables
  for update using (school = admin_school());

drop policy if exists "consumables_delete" on consumables;
create policy "consumables_delete" on consumables
  for delete using (school = admin_school());

create index if not exists idx_consumables_school on consumables(school);


-- ─────────────────────────────────────────────
-- 3. stock_log — Consumable movement history
-- ─────────────────────────────────────────────

create table if not exists stock_log (
  id              uuid primary key default gen_random_uuid(),
  consumable_id   uuid references consumables(id) on delete cascade,
  change          int not null,
  new_stock       int not null,
  reason          text,
  logged_by       uuid references auth.users(id),
  created_at      timestamptz default now()
);

alter table stock_log enable row level security;

drop policy if exists "stock_log_select" on stock_log;
create policy "stock_log_select" on stock_log
  for select using (
    exists (
      select 1 from consumables c
      where c.id = stock_log.consumable_id
      and c.school = admin_school()
    )
  );

drop policy if exists "stock_log_insert" on stock_log;
create policy "stock_log_insert" on stock_log
  for insert with check (
    exists (
      select 1 from consumables c
      where c.id = stock_log.consumable_id
      and c.school = admin_school()
    )
  );

create index if not exists idx_stock_log_consumable on stock_log(consumable_id);


-- ─────────────────────────────────────────────
-- 4. Helper: update consumable stock + log in one call
-- ─────────────────────────────────────────────

create or replace function public.adjust_stock(
  p_consumable_id uuid,
  p_change int,
  p_reason text default null
)
returns json
language plpgsql security definer set search_path = public as $$
declare
  c consumables;
  new_level int;
begin
  select * into c from consumables where id = p_consumable_id;
  if c.id is null then
    return json_build_object('ok', false, 'error', 'Consumable not found');
  end if;

  new_level := greatest(0, c.current_stock + p_change);

  update consumables
    set current_stock = new_level, updated_at = now(),
        last_restocked = case when p_change > 0 then now() else last_restocked end
    where id = p_consumable_id;

  insert into stock_log (consumable_id, change, new_stock, reason, logged_by)
    values (p_consumable_id, p_change, new_level, p_reason, auth.uid());

  return json_build_object(
    'ok', true,
    'new_stock', new_level,
    'below_threshold', new_level <= c.reorder_threshold
  );
end $$;

grant execute on function public.adjust_stock(uuid, int, text) to authenticated;


-- ─────────────────────────────────────────────
-- 5. Tag ID sequence helper
--    Generates the next tag_id for a given school + category prefix.
--    Format: {SCHOOL_CODE}-{PREFIX}-{SEQUENCE}
--    e.g. RJH-EQ-00142
-- ─────────────────────────────────────────────

create or replace function public.next_tag_id(
  p_school_code text,
  p_prefix text
)
returns text
language plpgsql security definer set search_path = public as $$
declare
  pattern text;
  max_seq int;
  next_seq int;
begin
  pattern := p_school_code || '-' || p_prefix || '-%';
  
  select max(
    cast(
      substring(tag_id from length(p_school_code) + length(p_prefix) + 3)
      as int
    )
  ) into max_seq
  from school_items
  where tag_id like pattern;

  next_seq := coalesce(max_seq, 0) + 1;

  return p_school_code || '-' || p_prefix || '-' || lpad(next_seq::text, 5, '0');
end $$;

grant execute on function public.next_tag_id(text, text) to authenticated;
