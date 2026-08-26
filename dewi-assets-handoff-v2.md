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

---

# Session Addendum — Dewi Assets Session Handoff
**Originally prepared:** July 24, 2026  
**Last updated:** August 21, 2026

---

## Session Log

### 2026-08-21 — Phase 0 Cleanup + Live Verification

**Process change adopted this session:** planning/review now happens in this
chat, Claude Code only executes narrowly-scoped, investigation-first prompts,
nothing is committed without explicit approval, and only disposable test
credentials are ever shared with Claude Code or automation tools. See
Lessons Learned for the incidents that led to this.

#### Phase 0 commits (main branch, in order, all pushed)
| Commit | What it did |
|---|---|
| `ed70f0e` | Removed `assets.html` — leftover Dewey-era textbook page, was live in production |
| `68d7265` | Fixed `DEWEY→DEWI` naming typos in CSS file headers (`dewi.css`, `dewi-assets.css`) |
| `b3ca3f3` | Removed the Settings nav link from `dewi-assets-school.html` sidebar, matching the pattern already applied to dashboard/cart/scan |
| `f14cd7c` | Added `.gitignore` — excludes `.DS_Store` and Google Drive temp artifacts |

#### The assets.html production incident
`assets.html` had been deleted from the working tree in an earlier session, but
the deletion was never committed — so it stayed live at
`dewi-assets.pages.dev/assets.html` until `ed70f0e` was pushed. It was a
renamed copy of the Dewi teacher-app's old textbook-scanning page (Dewey-era
naming, `DEWEY_SUPABASE_URL` constants, unrelated product entirely). Fixed as
part of Phase 0.

#### Confirmed-live verification (test-vp@school.ca, real browser session — not agent-reported)
| Feature | Result |
|---|---|
| Sign-in (email/password) | ✅ Working — routes to school dashboard |
| School dashboard | ✅ Working — real cart/device counts for Sir John A. Macdonald |
| Cart detail | ✅ Working — real slot/serial/student data (SN-TEST-001/002) |
| Serial search (scan page) | ✅ Working — full chain of custody for a real device (5CD3147XYZ), including condition-log history |
| CSV export (reports page) | ✅ Working — real data rows in the downloaded file |

This also confirmed the one thing flagged as highest-risk in an earlier
session: `admin_accounts.school` and `carts.school` match exactly for the
test account — the dashboard correctly showed Chris's real scanned classroom
cart data, not zero rows.

#### Still unverified
- **schema-v2 tables** (`school_items`, `consumables`, `stock_log`) — SQL
  exists in `dewi-assets-schema-v2.sql` but running it against live Supabase
  has never been confirmed
- **Board dashboard** — untested; no board-role test account exists yet
  (`orbidium@gmail.com` as board admin is unconfirmed/needs a fresh password
  if ever used, per credential-safety policy below)
- **Settings-save** — blocked on the same board-account gap

#### Pending, not yet committed
- A toast-easing CSS tweak in `dewi.css` (came out of an unplanned
  design-linter tangent, not part of Phase 0's actual scope) — sitting
  uncommitted in the working tree. No decision made yet on keeping it.

#### Roles/accounts decided this session
- Two separate logins (school-role, board-role) rather than a combined
  "superadmin" — no third role exists in the schema, and none is planned.
- `test-vp@school.ca` is the confirmed-working, safe-to-reuse test account
  for the foreseeable future.
- A parallel board-role test account still needs to be created — naming
  convention TBD, but should follow the same disposable-test-domain pattern.

#### Domain decision revised
- Earlier plan was `dewiassets.com` **and** `.ca`. **Revised this session: `.com` only** — simpler, and the product is an edtech admin tool where a `.ca`/`.com` split isn't expected to matter to users the way it might for a consumer brand.

---

### 2026-08-25/26 — Phase 6 Ship + Design Polish

#### What shipped (pushed live unless noted)

| Commit | What it did | Status |
|---|---|---|
| `b3ae957` | Fixed `asset_type` filter — Chromebook rows were missing from all inventory queries | Pushed |
| `065a50b` | Phase 6: Cart Naming Planner — `cart_plans` table + RLS + 3-step wizard UI + nav link | Pushed |
| `c0c0fda` | Sidebar sign-out control — added across all 10 sidebar pages, verified live (sign out → sign in → used the new "Plan Carts" nav item) | Pushed |
| `2eaac23` | Age-legend side-tab → dot swatch (dashboard) | Pushed |
| `97ee605` | Design polish: scan-cent dot accent, cart header top-border, reports toast easing, board topbar subtitle size | **Committed, pending review/push** |

#### Design polish detail (commit `97ee605`)

- **`dewi-assets.css` — `.scan-cent::before`:** replaced 4px vertical side-tab stripe with a 6px tobacco dot above the label (absolute-positioned within card padding)
- **`dewi-assets-cart.html` — `.cart-head`:** replaced `border-left: 4px solid var(--tobacco)` with `border-top: 2px solid var(--tobacco)`
- **`dewi-assets-reports.html` — toast transition:** swapped bounce easing `cubic-bezier(0.34, 1.56, 0.64, 1)` → smooth expo ease-out `cubic-bezier(0.16, 1, 0.3, 1)` (same fix already applied to `dewi.css` toast earlier)
- **`dewi-assets-board.html` — topbar subtitle:** `font-size` 11px → 9.5px; clears the 1.25× minimum step floor against the adjacent 12px button. Impeccable hook's `flat-type-hierarchy` rule for this file was suppressed (scoped to this file only) — the detector's proximity window was conflating the left-column title/subtitle pair (22px → 9.5px, ratio 2.3×) with unrelated right-column action elements at 12–13px.

#### Open items for next session (all small, none urgent)

1. **Three more files carrying identical patterns to fixes applied tonight** — same approved fix, just not yet propagated:
   - `dewi-assets-search.html` — same toast bounce-easing as `reports.html` (CSS class `.sr-toast`, L284)
   - `dewi-assets-settings.html` — same toast bounce-easing (inline style, L643)
   - `dewi-assets-school.html` — same age-legend side-tab as the dashboard had (`.age-legend-item`, L52)
2. **`dewi-assets-settings.html` — "Danger zone" card** (`border-left: 5px solid var(--burgundy)`, L176) — needs a treatment decision. Recommendation: swap to `border-top: 2px solid var(--burgundy)`, matching the cart header pattern, to keep visual weight appropriate for a destructive-action zone.
3. **Review and push** commit `97ee605` (design polish).
4. **Phase 8 (domain cutover)** — Cloudflare custom domain attachment (Chris, manual) and Supabase Auth redirect URL addition (Claude Code, pre-approved) were kicked off in parallel.
5. **GA4 property setup** (Chris) — once the Measurement ID exists, wiring the tracking snippet across all pages is a one-pass job, same approach as the sign-out button rollout.
6. **GSC (Search Console)** deliberately deferred — no public pages to index yet; revisit once a landing page exists post-pilot.

#### Still outstanding from earlier phases

- Phase 2 (office role + consumables)
- Phase 3 (board onboarding wizard — also seeds `board_schools` so the board test account isn't empty)
- Phase 5 (photo-scan port)
- Phase 7 (`dewi-assets-school.html` full data wiring)
- Phase 9 (pre-pilot QA pass)

---

### 2026-08-26 — Afternoon close-out: domain cutover complete, login hero, Phase 8 done

#### What shipped since the design-polish addendum

- **Sidebar logout** — confirmed live via real sign-out/sign-in click-through (not just DB-layer verification).
- **Phase 6 (Cart Naming Planner)** — confirmed live via real click-through: signed out, signed back in, clicked the new "Plan Carts" nav item, used it.
- **Design-polish commit `97ee605`** pushed and independently re-verified (not just trusted from the report): confirmed against `origin/main` source directly, and confirmed the `flat-type-hierarchy` suppression on `board.html` is real, correctly scoped to that one file only, and the hook now passes cleanly.
- **Domain cutover, mostly complete:**
  - `dewiassets.com` and `www.dewiassets.com` both attached as Cloudflare Pages custom domains, both **Active** with SSL enabled.
  - **Root-path 404 discovered and fixed** — this was a pre-existing gap, not something caused by tonight's work: `dewi-assets.pages.dev/` (bare root) had *always* 404'd because no `index.html` existed at the repo root; nobody had noticed because every real entry point is a named page (`/dewi-assets-login`, etc.). Fixed via a Cloudflare Pages `_redirects` file (`/ /dewi-assets-login 302`) — an edge-level HTTP redirect, not a client-side meta-refresh. Commit `5117f0a`. Verified via real `curl -v` showing `302` + correct `Location` header on both domains.
  - Login page confirmed working visually on `dewiassets.com` (real screenshot, form renders correctly, hero copy/testimonial in place).
- **Login hero image** (`dewi-assets-login-hero.jpg`) — real photo wired in, replacing the `admin-desk.png` placeholder. Uses the identical espresso-wash wrapper technique as the dashboard hero (`.login-photo-img` wrapper with `background-blend-mode: overlay` + dual gradient, copied from `.dash-hero-img`). Fabricated Margaret Chen testimonial removed; replaced with unattributed product tagline: *"Every Chromebook has a home. Every cart has an owner. No more walking the halls to find out where either one is."* Commit `c51c123`.

#### Phase 8 — now fully complete

The Supabase Auth redirect-URL gap flagged earlier in this session is closed. `https://dewiassets.com` and `https://www.dewiassets.com` were added manually via the dashboard (Authentication → URL Configuration), verified against a real screenshot: all 8 pre-existing entries untouched, 2 new entries present, **Total URLs: 10** confirmed. Note: Claude Code's own "expected list" of pre-existing entries was inaccurate (looked fabricated rather than actually checked) — the verification that mattered was the direct visual confirmation, not Claude Code's self-report.

**Phase 8 (domain cutover) is now fully done:** custom domains active with SSL, root-path redirect working, Auth redirect URLs correctly configured.

#### Still open (small, low-risk, previously identified)

1. Three repeated design-polish fixes, same approved treatment, not yet applied to their files:
   - `search.html` — toast bounce-easing (same as `reports.html`)
   - `settings.html` — toast bounce-easing (inline style)
   - `school.html` — age-legend side-tab (same as dashboard's, pre-fix)
2. `settings.html` "Danger zone" card border — decision made (swap to `border-top: 2px solid var(--burgundy)`, matching the cart-header pattern), not yet built.

#### Full remaining phase list (unchanged)

- Phase 2 — office role + consumables
- Phase 3 — board onboarding wizard (also seeds `board_schools` so the board test account isn't empty)
- Phase 5 — photo-scan port
- Phase 7 — `school.html` full data wiring
- Phase 9 — pre-pilot QA pass
- GA4 tracking snippet rollout (pending: Chris creating the GA4 property and getting a Measurement ID)
- GSC — deliberately deferred until a public landing page exists

---

## Why this doc exists

Dewi Assets was designed in an earlier Dewi chat ("Dewi 7," July 19), but the actual
build happened across one or more Claude Code (terminal) sessions that never appeared
in claude.ai chat history — nothing was lost, it just wasn't tracked anywhere visible.
This session's first job was establishing ground truth: verifying what's actually wired
to real data vs. designed-but-not-built, and confirming actual deployment status, rather
than trusting either the original handoff's status claims or agent self-reports.

**Standing rule for this doc, same as the main Dewi project:** treat every "done"/"built"
claim below as true as of the date it was verified, not as permanently true. Re-verify
against live code before relying on anything here in a future session.

---

## Where things stand right now

### Codebase — AUDITED, MOSTLY REAL

Reviewed every uploaded file directly (not agent-reported) against actual Supabase
query calls:

**Genuinely wired to live Supabase data** (`admin_accounts`, `board_schools`, `carts`,
`assets`, `students` — read-only on teacher-owned tables, confirmed no writes):
- `dewi-assets-login.html` — real Supabase Auth sign-in, role lookup, and invite
  acceptance via `db.rpc('accept_admin_invite', ...)`, which is a real Postgres function
  in `dewi-assets-schema.sql`
- `dewi-assets-dashboard.html`, `dewi-assets-board.html`, `dewi-assets-cart.html`,
  `dewi-assets-reports.html`, `dewi-assets-fleet.html` — all call `AssetsCore.loadInventory()`
  and render from the real result
- `dewi-assets-scan.html`, `dewi-assets-search.html` — real `AssetsCore.searchSerial()`
  calls against live data
- `dewi-assets-settings.html` — real inserts/updates/deletes on `admin_accounts`,
  `board_schools`, `admin_invites`

**Not wired — static mockup, confirmed on the live production site, not just in the
uploaded files:**
- `dewi-assets-school.html` — every number and name ("Northview Elementary," 342
  students, cart/device counts) is hand-typed HTML. `AssetsCore.boot()`'s `onReady` is
  empty with the comment `// School page data wiring is Phase 2 — auth gate is active.`
  Confirmed identical on a fresh pull from the live/GitHub source — this is genuinely
  what's in production right now, not a stale upload.
  - **Lower urgency than it first looked:** this page only loads via `allow: ['board']`
    — school-role admins are redirected to the dashboard instead. Since both VPs will
    log in as `school` role, they will never hit this page. Only matters for board-role
    testing (Chris's second login).

**Schema exists, zero frontend usage anywhere:**
- `dewi-assets-schema-v2.sql` defines `school_items`, `consumables`, `stock_log`
  (Category 2/3 inventory — tagged assets and stock-level consumables). Grepped every
  HTML file and `core.js` for these table names: no page queries or writes them. Even
  if this SQL has been run against the live Supabase project, there's currently no UI
  path to use it. Treat the "three-category inventory model" as schema-only, not built.

**Invite flow is real but manual:** `sendInvite()` in settings.html inserts a real row
into `admin_invites` and shows the invite code in a toast — there's no automated email.
The admin has to get that code to the invitee some other way (text, email, in person).

### Deployment — CONFIRMED LIVE

- **Host:** Cloudflare Pages (not Netlify — that was the source of confusion this
  session; Netlify is the Dewi *teacher app's* host, not Dewi Assets')
- **Repo:** `orbidium-netizen/dewi-assets` on GitHub — confirmed real and connected,
  auto-deploy from `main` branch is on
- **Live URL:** `dewi-assets.pages.dev` (no custom domain attached yet)
- **Deployment history:** real feature commits ("Align all pages to real assets
  tables," "Fix login panel scroll") landed roughly a month ago — this is almost
  certainly the session Chris remembers seeing it "live and working" with photos in
  June. Two most recent deploys (9 days ago) are Gitleaks/secret-scanning config only,
  not feature work — consistent with the schema-v2 gap above (no feature work has
  landed since the June session).
- **Not yet confirmed:** whether the exact live commit matches the files reviewed this
  session (GitHub API rate-limited mid-session before a direct diff could be pulled) —
  worth a quick recheck next session.

### Roles / accounts — DECIDED

- Two roles exist in the schema today: `school` and `board`. No third "superadmin"
  role — `admin_accounts.role` has a hard check constraint, and every page's
  `AssetsCore.boot({ allow: [...] })` gate checks against exactly those two values.
- **Decision:** Chris will use two separate logins (one `school`-role, one
  `board`-role) rather than building a combined role. No new code required.
- **The two VPs will log in as `school` role.** Their actual use case: access
  `dewiassets.com` throughout the year to look up where a specific (often lost)
  Chromebook is. This maps to the already-real `searchSerial()` flow — good match to
  what's built, see open item below on *how* they'll search.

### Domain — PLANNED, NOT YET DONE

- Chris plans to buy `dewiassets.com` (`.com` only — no `.ca` companion; revised
  2026-08-21, see Session Log for reasoning).
- Technically straightforward on Cloudflare Pages (attach as a custom domain to the
  existing project), but one thing must not be skipped:
  1. Add the domain to Supabase Auth's allowed redirect URLs / Site URL list —
     the main Dewi project already hit a live bug (Lesson #35) from exactly this kind
     of omission.

### Real pilot data — CONFIRMED TO EXIST

Chris scanned all Chromebooks on his own classroom cart (shared with a teaching
neighbour) via his real Dewi teacher profile — this is genuine, non-mock data now
sitting in `carts`/`assets` tied to Chris's real school.

**Verified 2026-08-21:** `admin_accounts.school` for `test-vp@school.ca` matches
`carts.school` exactly — the school dashboard correctly loaded Chris's real scanned
classroom cart data, confirming `getScope()`'s exact-string filter is working against
live data.

### Scanning method — OPEN QUESTION, LIKELY REAL BUILD WORK

- The AI photo-scan pattern (iPhone/Android photo → Cloudflare Worker
  `dewi-device-scan` → Claude Vision → structured JSON) is real, tested, and is what
  won the VPs over in the first place. Confirmed live in **`textbook.html`, part of
  the Dewi teacher app** — not Dewi Assets.
- `dewi-assets-scan.html` and `dewi-assets-search.html` (the admin-side lookup pages)
  are plain `<input type="text">` fields today — no camera, no file capture, nothing
  wired to `dewi-device-scan`.
- USB barcode scanners (tried: one cheap, one $100+ Zebra DS2208) were deliberately
  abandoned in favor of photo-scan — documented in the main project's Lessons Learned
  as a portfolio-wide standing rule now, not just a Dewi-specific workaround.
- **Open question, not yet answered:** when the VPs "scan Chromebooks" on
  `dewiassets.com` to find a lost one, do they expect to photograph the device the way
  the teacher-scan demo works, or type/search a serial they already have? If it's the
  former, porting photo-scan into the Dewi Assets admin search page is real unbuilt
  work — though the `dewi-device-scan` Worker's existing extraction schema (serial,
  asset ID, model) already matches what Dewi Assets needs, so it's a head start, not a
  from-scratch build.
- If this does get built, carry over the hard-won lessons from the main project's
  scanning saga (Lesson #34): don't fabricate serial-decode logic without a documented
  manufacturer spec, use a settle-timer rather than delimiter-gating on scan input, and
  keep the "no photos saved, processed in memory only" privacy framing — it's already
  a marketing differentiator for the teacher app and would carry over cleanly.

---

## Timeline

- Chris is going into the school a bit early (before the school year starts) to walk
  the two VPs through cart setup and scanning for the new year, and to show how Dewi
  and Dewi Assets work together.
- Pilot target: September 2026, both VPs on `school`-role accounts.

---

## Open decisions — not yet answered

1. **Scan method for Dewi Assets admin pages** — photo-scan port vs. text/USB search
   as-is. See above; probably the single biggest remaining scope question.
2. **`dewi-assets-school.html`** — patch before pilot, or leave as-is since only
   board-role (Chris's testing login) will ever see it?
3. **`school_items`/`consumables`/`stock_log`** — build UI for Category 2/3 inventory
   before pilot, or explicitly scope it out of the September pilot and revisit after?
4. **Superadmin role** — stick with two separate logins long-term, or eventually build
   a real combined role? (No urgency — two logins works fine for now.)

---

## Next session should start with

1. Re-attempt the GitHub API diff to confirm the live deploy matches what's been
   reviewed here (rate-limited this session, not yet done).
2. Get an answer on the scan-method open question above — it determines whether
   there's a real build sprint ahead or just polish/config work.

---

## Key files referenced this session

`dewi-assets-core.js`, `dewi-assets-login.html`, `dewi-assets-dashboard.html`,
`dewi-assets-board.html`, `dewi-assets-cart.html`, `dewi-assets-reports.html`,
`dewi-assets-scan.html`, `dewi-assets-search.html`, `dewi-assets-settings.html`,
`dewi-assets-school.html`, `dewi-assets-fleet.html`, `dewi-assets-schema.sql`,
`dewi-assets-schema-v2.sql`, `dewi-assets-claude-code-handoff.md` (original design
handoff, July 19 — status sections now stale, see note at top of this doc),
`LESSONS_LEARNED.md` (main Dewi project, referenced for the photo-scan and domain
patterns), `Dewi-Handoff.md` (main Dewi project's own July 18–23 handoff, referenced as
the format model for this doc).
