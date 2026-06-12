-- ============================================================
-- DEWI ASSETS — Admin layer schema + RLS
-- Run this ONCE in the Supabase SQL Editor (Console UI, not CLI)
-- Project: ivdkipygpasvowigarfb (same project as Dewi teacher app)
--
-- This file supersedes the SQL in the handoff doc. Two fixes:
--   1. The handoff's admin_accounts_select policy self-referenced
--      admin_accounts, which Postgres rejects at query time with
--      "infinite recursion detected in policy". Fixed with
--      SECURITY DEFINER helper functions.
--   2. The handoff defined no policies letting admins READ the
--      teacher tables (carts / assets / students). Without these,
--      every admin dashboard query returns zero rows. Added below
--      as ADDITIVE read-only policies — teacher policies are
--      untouched, and admins get no insert/update/delete on
--      teacher data (read-only by design).
-- ============================================================

-- ─────────────────────────────────────────────
-- 1. Tables
-- ─────────────────────────────────────────────

-- Admin accounts (separate from teacher auth)
-- Role: 'school' = VP/Principal, 'board' = district coordinator
create table if not exists admin_accounts (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  role       text not null default 'school'
             check (role in ('school', 'board')),
  full_name  text,
  school     text,         -- which school (for school admins)
  board      text,         -- which board/district
  prefs      jsonb default '{}'::jsonb,  -- province, fiscal year, budget, device cost
  created_at timestamptz default now(),
  last_seen  timestamptz
);
alter table admin_accounts enable row level security;

-- If the table already existed without prefs, add it:
alter table admin_accounts add column if not exists prefs jsonb default '{}'::jsonb;

-- Board/district structure — links schools to a board
create table if not exists board_schools (
  id          uuid primary key default gen_random_uuid(),
  board_id    uuid references admin_accounts(id),
  school_name text not null,
  school_code text,
  city        text,
  created_at  timestamptz default now()
);
alter table board_schools enable row level security;

-- Admin invites — pending invitations
create table if not exists admin_invites (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  role        text not null check (role in ('school', 'board')),
  school      text,
  board       text,
  invited_by  uuid references admin_accounts(id),
  expires_at  timestamptz default (now() + interval '7 days'),
  used_at     timestamptz,
  created_at  timestamptz default now()
);
alter table admin_invites enable row level security;

-- ─────────────────────────────────────────────
-- 2. SECURITY DEFINER helpers
--    These bypass RLS internally, which is what prevents the
--    infinite-recursion error and keeps policies fast.
-- ─────────────────────────────────────────────

create or replace function public.admin_role() returns text
language sql security definer stable set search_path = public as
$$ select role from admin_accounts where id = auth.uid() $$;

create or replace function public.admin_school() returns text
language sql security definer stable set search_path = public as
$$ select school from admin_accounts where id = auth.uid() $$;

create or replace function public.admin_board() returns text
language sql security definer stable set search_path = public as
$$ select board from admin_accounts where id = auth.uid() $$;

-- All school names this admin is entitled to see
create or replace function public.admin_school_names() returns setof text
language sql security definer stable set search_path = public as
$$
  select a.school from admin_accounts a
    where a.id = auth.uid() and a.role = 'school' and a.school is not null
  union
  select bs.school_name from board_schools bs
    join admin_accounts a on a.id = auth.uid() and a.role = 'board'
    where bs.board_id = a.id
$$;

-- All cart ids this admin is entitled to see
create or replace function public.admin_cart_ids() returns setof uuid
language sql security definer stable set search_path = public as
$$ select c.id from carts c where c.school in (select admin_school_names()) $$;

grant execute on function public.admin_role()         to authenticated;
grant execute on function public.admin_school()       to authenticated;
grant execute on function public.admin_board()        to authenticated;
grant execute on function public.admin_school_names() to authenticated;
grant execute on function public.admin_cart_ids()     to authenticated;

-- ─────────────────────────────────────────────
-- 3. Policies — admin tables
-- ─────────────────────────────────────────────

drop policy if exists "admin_accounts_select" on admin_accounts;
create policy "admin_accounts_select" on admin_accounts
  for select using (
    id = auth.uid()
    or (admin_role() = 'board' and board = admin_board())
  );

drop policy if exists "admin_accounts_update_own" on admin_accounts;
create policy "admin_accounts_update_own" on admin_accounts
  for update using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "board_schools_select" on board_schools;
create policy "board_schools_select" on board_schools
  for select using (
    board_id = auth.uid()
    or (admin_role() = 'school' and school_name = admin_school())
  );

drop policy if exists "board_schools_insert" on board_schools;
create policy "board_schools_insert" on board_schools
  for insert with check (board_id = auth.uid() and admin_role() = 'board');

drop policy if exists "board_schools_update" on board_schools;
create policy "board_schools_update" on board_schools
  for update using (board_id = auth.uid());

drop policy if exists "board_schools_delete" on board_schools;
create policy "board_schools_delete" on board_schools
  for delete using (board_id = auth.uid());

drop policy if exists "admin_invites_select" on admin_invites;
create policy "admin_invites_select" on admin_invites
  for select using (invited_by = auth.uid());

drop policy if exists "admin_invites_insert" on admin_invites;
create policy "admin_invites_insert" on admin_invites
  for insert with check (invited_by = auth.uid() and admin_role() = 'board');

drop policy if exists "admin_invites_delete" on admin_invites;
create policy "admin_invites_delete" on admin_invites
  for delete using (invited_by = auth.uid());

-- ─────────────────────────────────────────────
-- 4. Policies — ADDITIVE read-only admin access to teacher tables
--    Existing teacher policies (teacher_id = auth.uid()) are untouched.
--    Postgres ORs multiple permissive policies, so teachers keep
--    exactly the access they have today.
-- ─────────────────────────────────────────────

drop policy if exists "carts_admin_select" on carts;
create policy "carts_admin_select" on carts
  for select using (school in (select admin_school_names()));

drop policy if exists "assets_admin_select" on assets;
create policy "assets_admin_select" on assets
  for select using (cart_id in (select admin_cart_ids()));

drop policy if exists "students_admin_select" on students;
create policy "students_admin_select" on students
  for select using (cart_id in (select admin_cart_ids()));

-- ─────────────────────────────────────────────
-- 5. Invite acceptance (called from the login page with the
--    invite code). SECURITY DEFINER so a brand-new auth user can
--    create their own admin_accounts row from a valid invite.
-- ─────────────────────────────────────────────

create or replace function public.accept_admin_invite(invite_code uuid)
returns json
language plpgsql security definer set search_path = public as $$
declare
  inv    admin_invites;
  uemail text;
begin
  if auth.uid() is null then
    return json_build_object('ok', false, 'error', 'Not signed in');
  end if;

  select email into uemail from auth.users where id = auth.uid();

  select * into inv from admin_invites
    where id = invite_code and used_at is null and expires_at > now();

  if inv.id is null then
    return json_build_object('ok', false, 'error', 'Invite not found, already used, or expired');
  end if;

  if lower(inv.email) <> lower(uemail) then
    return json_build_object('ok', false, 'error', 'This invite was issued to a different email address');
  end if;

  insert into admin_accounts (id, email, role, school, board)
    values (auth.uid(), uemail, inv.role, inv.school, inv.board)
    on conflict (id) do update
      set role = excluded.role, school = excluded.school, board = excluded.board;

  update admin_invites set used_at = now() where id = inv.id;

  return json_build_object('ok', true, 'role', inv.role);
end $$;

grant execute on function public.accept_admin_invite(uuid) to authenticated;

-- ─────────────────────────────────────────────
-- 6. Test data bootstrap (Section 19 of the handoff)
--    Run AFTER creating the board admin user in Supabase Auth UI.
--    Replace <AUTH_UID> with the new user's UUID.
-- ─────────────────────────────────────────────
-- insert into admin_accounts (id, email, role, full_name, board)
--   values ('<AUTH_UID>', 'orbidium@gmail.com', 'board', 'Chris', 'Test Board');
-- insert into board_schools (board_id, school_name, city)
--   values ('<AUTH_UID>', 'Sir John A. Macdonald', 'Bedford');
--
-- NOTE: existing teacher cart data appears under that school
-- automatically once carts.school matches board_schools.school_name
-- exactly (case-sensitive string match).
--
-- ALSO: enable Email provider sign-ups in Supabase Auth settings,
-- or invite-code signups from the login page will fail.
