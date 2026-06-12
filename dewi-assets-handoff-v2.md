# Dewi Assets — Claude Code Build Handoff (v2)
**Updated:** June 2026  
**Product:** Dewi Assets — School & District Device + Inventory Platform  
**Company:** Anchored Development Co. (Halifax, Nova Scotia, Canada)  
**Status:** Phase 1 code complete (auth, dashboards, search, reports, settings wired to Supabase). Phase 2 schema expansion ready.

---

## How to Use This Document

This is a step-by-step build guide. Work through it **one section at a time** with the developer. Do not jump ahead. Each step should be verified before moving to the next.

The existing codebase (all HTML, CSS, JS, SQL files in this folder) was built in a prior session. It covers Priority 1–8 from the original handoff:
- ✅ Auth (login, role routing, invite acceptance)
- ✅ School dashboard (live from Supabase carts/assets/students)
- ✅ Cart detail view
- ✅ Board dashboard (aggregated school data)
- ✅ Serial search (scan and search pages)
- ✅ Fleet health table
- ✅ CSV exports in reports
- ✅ Settings (board profile, schools CRUD, admin invites)

**What still needs to be done** (this document's focus):
1. Deploy and verify each existing page against real Supabase data
2. Expand the schema for the full inventory model (tagged assets, consumables)
3. Wire the school page as a full inventory hub (not just devices)
4. QR label generation for tagged assets

---

## 1. Stack (unchanged)

| Layer | Technology | Notes |
|---|---|---|
| Frontend | Vanilla HTML/CSS/JS | No frameworks |
| Database | Supabase (Postgres + Auth) | Same project as Dewi teacher app |
| Hosting | Cloudflare Pages | Auto-deploys from GitHub |
| Auth | Supabase email/password | Admins only — no Google OAuth |
| Shared module | `dewi-assets-core.js` | Auth gate, data layer, helpers — every page uses this |

**Supabase credentials:** see any HTML file's `<script>` block.

---

## 2. Naming Rules — Non-Negotiable

- Product: **Dewi Assets** (never "Dewey")
- Teacher app: **Dewi** (never "Dewey")
- Company: **Anchored Development Co.**
- CSS files: `dewi.css`, `dewi-assets.css`, `dewi-board.css`
- All internal links: `dewi-assets-*.html` (never `dewey-assets-*`)

---

## 3. Safari + Supabase Rules — Never Break These

These are in every HTML file already. Never deviate.

1. Supabase CDN uses `onload="initSupabase()"` pattern
2. `let db = null;` at top, `initSupabase()` sets it in try/catch
3. `sessionHandledOnLoad` guard in `core.js` prevents SIGNED_IN refiring on tab focus
4. `waitForDbThenAuth()` polls for `db` before calling `initAuth()`
5. Never send `""` to Supabase — use `null` for empty optional fields
6. `parseInt() || null` for integer columns
7. Always give complete deployable files — never diffs or partial snippets

---

## 4. The Three Inventory Categories

Dewi Assets tracks three fundamentally different kinds of items. The database schema must handle all three from day one.

### Category 1 — Serialized Tech Assets
Individual items with a manufacturer serial number. Each gets its own database record. **Visible to both school admins and board admins.**

Examples: Chromebooks, iPads, laptops, tablets, any tech with a serial number.

**Data source:** Teachers scan these into carts using the Dewi teacher app (`assets` table). Admins see them read-only in Dewi Assets. This is already built and working.

### Category 2 — Tagged Assets (Admin-Created)
Items without a manufacturer serial number. The admin creates the record and Dewi Assets generates a QR code label. The label is printed, physically attached to the item, and from then on scanning the QR pulls up the record.

Examples: gym equipment (volleyballs, mats, nets), furniture (desks, chairs, whiteboards), musical instruments without serials, AV equipment, calculators, any item the school wants to track individually.

**Key distinction: tagged assets can be tech or non-tech.**
- Tagged tech (e.g., a calculator with no serial, a projector): **Visible to board admins**
- Tagged non-tech (e.g., volleyballs, desks): **School-only — board never sees these**

The admin picks the category when creating the item. The visibility follows automatically.

### Category 3 — Consumables
Bulk quantity items tracked as stock levels, not individual records. No serial, no QR label — just a count that goes up (restock) and down (usage) over time.

Examples: photocopier paper (cases), paper towel (cases), toilet paper, printer ink/toner, classroom supplies in bulk.

**Always school-only. Board admins never see consumables.** A school's paper towel supply is their business. Furthermore, bathroom supplies might be controlled by an entirely different entity within the board structure — not something the tech coordinator needs in their view.

Consumables trigger reorder alerts when stock drops below a threshold set by the school admin.

---

## 5. The Visibility Model

This is the critical design rule:

```
Tech (serialized or tagged)     → School admin sees it
                                → Board admin sees it
                                → Appears on board dashboard, fleet health, reports

Non-tech tagged assets          → School admin sees it
                                → Board admin does NOT see it
                                → Never appears on board-level pages

Consumables                     → School admin sees it
                                → Board admin does NOT see it
                                → Never appears on board-level pages
```

The school decides what they want to track. The board only sees tech. This is enforced by RLS policies in Postgres — not by frontend filtering.

---

## 6. Existing Tables (from Dewi teacher app — read-only to admins)

```sql
carts (id, teacher_id, cart_number, cart_name, school, shared_classes, room_number, created_at)
assets (id, teacher_id, cart_id, slot_number, serial_number, manufacturer, model, purchase_year, notes jsonb, created_at)
students (id, teacher_id, username, cart_id, slot_number, created_at)
```

Admins read these via additive RLS policies (`carts_admin_select`, `assets_admin_select`, `students_admin_select`) already deployed in `dewi-assets-schema.sql`.

---

## 7. Existing Admin Tables (deployed in prior session)

```sql
admin_accounts (id, email, role, full_name, school, board, prefs jsonb, created_at, last_seen)
board_schools (id, board_id, school_name, school_code, city, created_at)
admin_invites (id, email, role, school, board, invited_by, expires_at, used_at, created_at)
```

Plus SECURITY DEFINER helpers: `admin_role()`, `admin_school()`, `admin_board()`, `admin_school_names()`, `admin_cart_ids()`.

Plus `accept_admin_invite(uuid)` RPC for invite-code signup.

---

## 8. NEW Tables — Tagged Assets + Consumables

These need to be created. Run in Supabase SQL Editor (Console UI).

### school_items — Admin-created inventory items

```sql
create table if not exists school_items (
  id              uuid primary key default gen_random_uuid(),
  school          text not null,          -- must match board_schools.school_name and carts.school
  created_by      uuid references auth.users(id),
  
  -- Identity
  item_name       text not null,          -- e.g. "Yamaha YSL-354 Trombone", "Volleyball net"
  description     text,
  category        text not null default 'equipment'
                  check (category in ('tech', 'equipment', 'furniture', 'instruments', 'supplies', 'other')),
  
  -- Visibility: derived from category by default, admin can override
  -- 'board' = visible to school + board admins
  -- 'school' = visible to school admin only
  visibility      text not null default 'school'
                  check (visibility in ('school', 'board')),
  
  -- Identification (at least one should be filled)
  serial_number   text,                   -- manufacturer serial if it has one
  tag_id          text unique,            -- generated QR code ID for tagged items (e.g. "RJH-EQ-00142")
  
  -- Details
  manufacturer    text,
  model           text,
  location        text,                   -- room number, gym, closet, band room, etc.
  purchase_year   int,
  purchase_cost   numeric(10,2),
  condition       text default 'good'
                  check (condition in ('excellent', 'good', 'fair', 'poor', 'damaged', 'lost', 'retired')),
  quantity        int default 1,          -- usually 1 for individual items; >1 for bulk-but-tracked sets
  
  -- Metadata
  notes           jsonb default '{}'::jsonb,  -- aue, warranty_expiry, photos, custom fields
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

alter table school_items enable row level security;

-- School admins see their own school's items
-- Board admins see only tech-visibility items across their schools
create policy "school_items_select" on school_items
  for select using (
    (admin_role() = 'school' and school = admin_school())
    or (admin_role() = 'board' and visibility = 'board' and school in (select admin_school_names()))
  );

-- School admins can create/edit/delete items at their school
create policy "school_items_insert" on school_items
  for insert with check (school = admin_school());

create policy "school_items_update" on school_items
  for update using (school = admin_school());

create policy "school_items_delete" on school_items
  for delete using (school = admin_school());
```

### consumables — Stock-level tracking

```sql
create table if not exists consumables (
  id                uuid primary key default gen_random_uuid(),
  school            text not null,
  created_by        uuid references auth.users(id),
  
  -- Identity
  item_name         text not null,          -- e.g. "Photocopier paper, letter, white"
  description       text,
  category          text default 'supplies'
                    check (category in ('paper', 'cleaning', 'ink_toner', 'classroom', 'bathroom', 'other')),
  
  -- Stock tracking
  unit              text not null default 'case',   -- case, box, roll, cartridge, ream, etc.
  current_stock     int not null default 0,
  reorder_threshold int default 5,                  -- alert when stock drops to this level
  reorder_quantity  int,                             -- suggested reorder amount
  
  -- Purchasing
  supplier          text,
  unit_cost         numeric(10,2),
  
  -- Location
  location          text,                  -- storage room, janitor's closet, etc.
  managed_by        text,                  -- who handles restocking (e.g. "custodial", "office", "teacher")
  
  -- Metadata
  last_restocked    timestamptz,
  notes             jsonb default '{}'::jsonb,
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

alter table consumables enable row level security;

-- Consumables are ALWAYS school-only. Board admins never see them.
create policy "consumables_select" on consumables
  for select using (admin_role() = 'school' and school = admin_school());

create policy "consumables_insert" on consumables
  for insert with check (school = admin_school());

create policy "consumables_update" on consumables
  for update using (school = admin_school());

create policy "consumables_delete" on consumables
  for delete using (school = admin_school());
```

### stock_log — Consumable movement history

```sql
create table if not exists stock_log (
  id              uuid primary key default gen_random_uuid(),
  consumable_id   uuid references consumables(id) on delete cascade,
  change          int not null,           -- positive = restock, negative = usage
  new_stock       int not null,           -- stock level after this change
  reason          text,                   -- "Monthly restock", "Used for event", etc.
  logged_by       uuid references auth.users(id),
  created_at      timestamptz default now()
);

alter table stock_log enable row level security;

create policy "stock_log_select" on stock_log
  for select using (
    exists (
      select 1 from consumables c
      where c.id = stock_log.consumable_id
      and c.school = admin_school()
    )
  );

create policy "stock_log_insert" on stock_log
  for insert with check (
    exists (
      select 1 from consumables c
      where c.id = stock_log.consumable_id
      and c.school = admin_school()
    )
  );
```

---

## 9. Auto-Visibility Rule

When a school admin creates a `school_items` record:
- If `category = 'tech'` → `visibility` defaults to `'board'`
- All other categories → `visibility` defaults to `'school'`

The admin can override this manually. The frontend should set the default and show a toggle: "Also visible to board administrators" (on by default for tech, off for everything else).

---

## 10. Tag ID Format

Generated QR labels use the format: `{SCHOOL_CODE}-{CATEGORY_PREFIX}-{SEQUENCE}`

Examples:
- `RJH-EQ-00142` (Riverside Junior High, equipment, item 142)
- `CMH-IN-00003` (Cape Mira High, instrument, item 3)
- `RJH-TC-00089` (Riverside Junior High, tech, item 89)

Category prefixes: `TC` (tech), `EQ` (equipment), `FN` (furniture), `IN` (instruments), `SP` (supplies), `OT` (other).

The tag_id is generated by the frontend when the admin creates a tagged item. It must be unique (enforced by the `unique` constraint on `school_items.tag_id`).

---

## 11. Claude Code Step-by-Step Build Checklist

Work through these in order. Verify each step before moving on.

### Step A — Deploy and verify existing code
1. Create GitHub repo `orbidium-netizen/dewi-assets`
2. Push all files from this folder
3. Set up Cloudflare Pages pointing at the repo
4. Run `dewi-assets-schema.sql` in Supabase SQL Editor
5. Create board admin user in Supabase Auth (orbidium@gmail.com)
6. Insert test `admin_accounts` and `board_schools` rows
7. Verify: login page → board dashboard → school cards appear (may be empty until teacher data matches)

### Step B — Verify each existing page
8. Sign in as board admin → board dashboard loads, shows schools
9. Navigate to settings → board profile form saves to Supabase
10. Add a school in settings → appears in board_schools
11. Create an invite → appears in admin_invites
12. Navigate to fleet health → table loads (may be empty)
13. Navigate to device search → serial search returns results if teacher data exists
14. Navigate to reports → CSV exports download
15. Sign in as school admin (create one via invite) → school dashboard loads
16. Navigate to cart detail → slot table renders
17. Navigate to scan → serial lookup works

### Step C — Expand schema for full inventory
18. Run the `school_items`, `consumables`, and `stock_log` table creation SQL
19. Verify RLS: board admin cannot see `consumables` or non-tech `school_items`
20. Verify RLS: school admin can CRUD all three tables for their school

### Step D — Wire school page as inventory hub
21. Redesign `dewi-assets-school.html` with three tabs: **Devices** | **Inventory** | **Supplies**
22. Devices tab: existing teacher-scanned assets (read-only, from `assets` table via carts)
23. Inventory tab: `school_items` with add/edit/delete, category filters, QR generation
24. Supplies tab: `consumables` with stock levels, restock/use buttons, reorder alerts

### Step E — QR label generation
25. Generate tag_id when admin creates a tagged item
26. Render QR code on screen (use a JS QR library, no server needed)
27. Print sheet of QR stickers (CSS @media print layout)
28. Scan a QR → serial search finds the school_item by tag_id

### Step F — Board dashboard expansion
29. Board dashboard hero stats should include tech items from `school_items` (visibility='board')
30. Fleet health should include tech `school_items` alongside teacher-scanned `assets`
31. Reports CSV exports should include both data sources

---

## 12. Permissions Model (3 Roles — unchanged)

```
Teacher
  └── Dewi teacher app only — no access to Dewi Assets
  └── Scans devices into carts, assigns students

School Admin (VP / Principal)
  └── Dewi Assets login with email/password
  └── Sees ALL carts + devices at their school (read-only from teacher data)
  └── Full CRUD on school_items and consumables
  └── Sees tech + non-tech + consumables for their school
  └── Cannot see other schools

Board Admin (district technology coordinator)
  └── Dewi Assets login with email/password
  └── Sees ALL schools in their board
  └── Sees tech assets across all schools (from `assets` AND `school_items` where visibility='board')
  └── Does NOT see non-tech school_items or consumables — ever
  └── Cross-school device search, fleet health, reports
  └── Creates and manages school admin accounts
```

---

## 13. Design System (unchanged)

- **Tobacco brown** (`#6B4C2A`) — primary accent throughout Assets
- **Cormorant Garamond** — display text, headings, stat numerals
- **Jost** — body, labels, nav, buttons
- **Health colours:** green (good), amber (warn), red/burgundy (bad)
- **Never use forest green in Assets pages** — that's the teacher app

---

## 14. File Manifest

| File | What it does |
|---|---|
| `dewi-assets-core.js` | Shared auth gate + data layer (boot, loadInventory, searchSerial, helpers) |
| `dewi-assets-schema.sql` | Admin tables + RLS + helpers (already deployed) |
| `dewi-assets-schema-v2.sql` | NEW: school_items + consumables + stock_log tables (Section 8 above) |
| `dewi-assets-login.html` | Auth: sign in, invite-code signup, role routing |
| `dewi-assets-dashboard.html` | School admin dashboard — live carts/devices/stats |
| `dewi-assets-cart.html` | Cart detail — slot table with filter/sort/export |
| `dewi-assets-board.html` | Board admin dashboard — all schools, AUE alerts |
| `dewi-assets-scan.html` | School-level serial search with chain of custody |
| `dewi-assets-search.html` | Board-level cross-school device search |
| `dewi-assets-fleet.html` | Fleet health — filterable device table |
| `dewi-assets-reports.html` | CSV exports (full inventory, expiring, unassigned) |
| `dewi-assets-settings.html` | Board profile, schools CRUD, admin invites, danger zone |
| `dewi-assets-school.html` | Individual school page (board view) — NEEDS EXPANSION for full inventory |
| `dewi.css` | Teacher app design tokens (shared) |
| `dewi-assets.css` | Assets tobacco brown tokens |
| `dewi-board.css` | Board-level page styles |

---

## 15. What NOT to Build Yet

- AI photo scanning (photograph a device → AI identifies it) — Phase 3
- Inter-school device transfer logging — Phase 2
- PDF report generation (real PDFs) — stub with window.print() for now
- Mobile app — browser only
- Marketing/landing page
- Consumable auto-ordering integrations
- Dewi Assets label printing for non-serialised items (except the basic QR sheet in Step E)

---

*End of handoff v2. Work through the checklist step by step.*
