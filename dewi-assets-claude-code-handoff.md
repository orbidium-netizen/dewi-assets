# Dewi Assets — Claude Code Build Handoff
**Prepared:** June 2026  
**Product:** Dewi Assets — School & District Device Inventory Platform  
**Company:** Anchored Development Co. (Halifax, Nova Scotia, Canada)  
**Status:** Designs complete · Backend wiring and board-level pages ready to build  

---

## 1. What Is Dewi Assets

Dewi Assets is a school device inventory platform for administrators — vice-principals, principals, and district/board technology coordinators. It is a **separate product** from Dewi (the teacher classroom library app) but runs on the **same Supabase project**.

The core problem it solves: Google Admin Console tells IT staff which Chromebooks are enrolled, but not which student has which device physically in their hands. Spreadsheets are what most schools use today. Dewi Assets replaces both with a scan-in/scan-out system that works for all asset types — not just Chromebooks.

**The critical insight:** Teachers already scan devices into carts using the Dewi teacher app (textbook.html → Device Inventory tab). Dewi Assets gives administrators a live read-only view of that data — plus their own admin tools — without teachers ever entering anything twice.

---

## 2. Naming Rules — Non-Negotiable

- The product is **Dewi Assets** throughout. Never "Dewey Assets" — that spelling was retired.
- The teacher app is **Dewi**. Never "Dewey".
- The wordmark renders as: `Dewi` + `Assets` (Assets in tobacco brown italic)
- Company: **Anchored Development Co.**
- Domains: `getdewi.ca` (teacher app) · Dewi Assets will live at its own subdomain

---

## 3. Stack

| Layer | Technology | Notes |
|---|---|---|
| Frontend | Vanilla HTML/CSS/JS | No frameworks. Same as all Dewi products. |
| Database | Supabase (Postgres + Auth) | Same project as Dewi teacher app |
| Hosting | Cloudflare Pages | Auto-deploys from GitHub |
| Deployment | GitHub → Cloudflare Pages | Via Antigravity push tool |
| Auth | Supabase email/password | NOT Google OAuth — admins use email/invite |

**Supabase project credentials:**
```
URL: https://ivdkipygpasvowigarfb.supabase.co
Anon key: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Iml2ZGtpcHlncGFzdm93aWdhcmZiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcxMzA2NzcsImV4cCI6MjA5MjcwNjY3N30.qKN6tCqyyIIVoPAVl1o2_2gtUkfBh2aBWDP_sIDcxgE
```

---

## 4. Safari Rules — Never Break These

These are hard-won rules from the Dewi teacher app. Violating them causes silent failures on Safari/iOS.

1. **Supabase CDN always uses onload pattern:**
   ```html
   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2" onload="initSupabase()"></script>
   ```
2. **Never `const db = createClient(...)` at top level.** Always:
   ```js
   let db = null;
   function initSupabase() {
     try { const { createClient } = supabase; db = createClient(URL, KEY); }
     catch(e) { console.error('Supabase init failed:', e.message); }
   }
   ```
3. **`sessionHandledOnLoad` guard** — prevents `SIGNED_IN` firing on tab focus
4. **`waitForDbThenAuth()`** — polls for `db` before calling `initAuth()`
5. **Always give complete deployable files** — never diffs or partial snippets

---

## 5. Supabase Rules — Never Break These

- Always send `null` for empty optional fields, never `""`
- Integer columns: `parseInt() || null` — never send empty string
- Array columns: always `Array.isArray()` before `.split()`
- `teacher_id` = `auth.uid()` — this is the key convention across ALL tables
- `syncAndMerge` must NEVER upsert existing rows — overwrites critical fields
- Auth token expiry causes silent save failures — handle gracefully

---

## 6. Design System

### dewi.css (teacher app tokens — available to Assets pages)
```
--forest: #2C4A35    (teacher app green — DO NOT use in Assets)
--mustard: #8B6914
--burgundy: #6B2737
--paper: #FAF6EF
--cream: #F5EFE4
--ink: #1E1610
--ink-soft: (muted ink)
--ink-ghost: (very muted ink)
```

### dewi-assets.css (Assets-specific tokens)
```
--tobacco: #6B4C2A          (primary accent — all CTAs, active states)
--tobacco-mid: #7d5a32      (hover states)
--tobacco-deep: #3d2a14     (sidebar background)
--tobacco-lt: #f5ede2       (light tobacco tint — card backgrounds)
--tobacco-glow: rgba(107,76,42,0.15)  (focus rings)
--health-good: (green)
--health-warn: (amber)  
--health-bad: (red/burgundy)
```

### Typography
- **Cormorant Garamond** — all display text, wordmarks, hero titles, card headings
- **Jost** — body, labels, nav, stats labels, buttons
- Never use forest green in Assets pages — tobacco brown only

### Sidebar
- Dark tobacco background (`--tobacco-deep`)
- Dot-nav pattern — active dot in `--tobacco`
- Board context card at top of nav
- User avatar (R. MacIntyre) at bottom

---

## 7. Existing Supabase Tables (from Dewi teacher app)

These tables exist and contain real data. Dewi Assets reads from them but **never writes teacher data** from the admin side.

```sql
-- Teacher-created carts
carts (
  id uuid,
  teacher_id uuid,      -- = auth.uid() of teacher
  cart_number int,
  cart_name text,
  school text,
  shared_classes text,
  room_number text,
  created_at timestamptz
)

-- Devices scanned into carts by teachers
assets (
  id uuid,
  teacher_id uuid,
  cart_id uuid,
  slot_number int,
  serial_number text,
  manufacturer text,
  model text,
  purchase_year int,
  notes jsonb,          -- contains AUE data: { aue: '2029-06', condition: 'good' }
  created_at timestamptz
)

-- Students (anonymous usernames only — no real names)
students (
  id uuid,
  teacher_id uuid,
  username text,
  cart_id uuid,
  slot_number int,
  created_at timestamptz
)
```

---

## 8. New Tables to Create for Assets Admin Layer

Run these in Supabase SQL Editor before building:

```sql
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
  created_at timestamptz default now(),
  last_seen  timestamptz
);
alter table admin_accounts enable row level security;

-- Board admins can see all admin_accounts in their board
-- School admins can only see their own record
create policy "admin_accounts_select" on admin_accounts
  for select using (
    auth.uid() = id
    or exists (
      select 1 from admin_accounts a
      where a.id = auth.uid()
      and a.role = 'board'
      and a.board = admin_accounts.board
    )
  );

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

create policy "board_schools_select" on board_schools
  for select using (
    exists (
      select 1 from admin_accounts a
      where a.id = auth.uid()
      and a.role = 'board'
      and a.id = board_schools.board_id
    )
  );

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
```

---

## 9. Permissions Model (3 Roles)

```
Teacher
  └── Uses Dewi teacher app only
  └── Scans devices into carts, assigns to students
  └── NO access to Dewi Assets ever

School Admin (VP / Principal / designated teacher)
  └── Logs into Dewi Assets with email/password
  └── Sees ALL carts at their assigned school
  └── Read-only view of teacher-entered device data
  └── Can manage non-tech inventory at school level
  └── Cannot see other schools
  └── Account created by a Board Admin via invite

Board Admin (district technology coordinator / superintendent)
  └── Logs into Dewi Assets with email/password  
  └── Sees ALL schools in their board
  └── Cross-school device search
  └── Fleet health across all schools
  └── Reports for budget/procurement
  └── Creates and manages School Admin accounts
  └── Top-level account — set up during onboarding
```

**Permission grant flow:**
1. Board Admin account created during initial board setup
2. Board Admin invites School Admins via email → 7-day invite link
3. School Admin accepts invite, sets password, gains access to their school
4. Teachers are never involved in this flow

---

## 10. File Manifest — Designed Pages (upload these)

These pages were designed by Claude Design and are visually complete. They need backend wiring only.

| File | Status | Needs |
|---|---|---|
| `dewi-assets-login.html` | ✅ Designed | Wire Supabase email/password auth |
| `dewi-assets-dashboard.html` | ✅ Designed | Wire real data from assets + carts tables |
| `dewi-assets-cart.html` | ✅ Designed | Wire cart detail view from Supabase |
| `dewi-assets-scan.html` | ✅ Designed | Wire serial search across assets table |
| `dewi-assets-board.html` | ✅ Designed | Wire board-level data aggregation |
| `dewi-assets-fleet.html` | ✅ Designed | Wire AUE timeline from assets.notes.aue |
| `dewi-assets-search.html` | ✅ Designed | Wire cross-board serial search |
| `dewi-assets-reports.html` | ✅ Designed | Wire CSV export + PDF generation stubs |
| `dewi-assets-settings.html` | ✅ Designed | Wire board profile + admin management |

**Supporting files:**
| File | Notes |
|---|---|
| `dewi.css` | Teacher app design tokens — Assets pages link this |
| `dewi-assets.css` | Assets-specific tobacco brown tokens |

---

## 11. Images (drop into `images/` folder)

| Filename | Used on | Description |
|---|---|---|
| `admin-desk.png` | Login page left panel | Administrator desk, warm morning light, laptop |
| `chromebook-cart.png` | School dashboard hero | Chromebooks charging in cart, warm ambient light |
| `chromebook-serial-macro.png` | Scan page hero background | Close-up serial number label + QR code |
| `school-hallway.png` | Board dashboard hero | Heritage school hallway, yellow/teal lockers |
| `school-hallway2.png` | Individual school page hero | Northview Elementary, modern, floor-to-ceiling windows |

All images use `onerror="this.style.display='none'"` — pages degrade gracefully without them.

---

## 12. What Claude Code Needs to Build

### Priority 1 — Auth (blocks everything else)
Wire `dewi-assets-login.html` to Supabase email/password auth:
- Sign in → check `admin_accounts` table for role
- Role = 'school' → redirect to `dewi-assets-dashboard.html`
- Role = 'board' → redirect to `dewi-assets-board.html`
- Invalid credentials → show error in login form
- Session persistence — stay signed in across tabs
- Sign out in settings page

### Priority 2 — School Dashboard Data
Replace all hardcoded mock data in `dewi-assets-dashboard.html`:
- Load all carts for this admin's school from `carts` table
- Load all devices from `assets` table joined to those carts
- Calculate stats: total devices, Chromebooks, iPads, unassigned, damaged
- AUE data lives in `assets.notes` as JSON: `{ aue: '2029-06' }`
- Parse AUE dates to calculate expiring this year / within 12 months

### Priority 3 — Cart Detail
Wire `dewi-assets-cart.html`:
- Load single cart by ID from `carts` table
- Load all devices in that cart from `assets`
- Load student assignments from `students` (slot_number matches)
- Display slot → serial → model → student username chain

### Priority 4 — Board Dashboard
Wire `dewi-assets-board.html`:
- Load all schools for this board from `board_schools`
- For each school, aggregate device counts from `assets` via `carts`
- School health badge: REPLACE (>15% expiring) · WATCH (5-15%) · HEALTHY (<5%)
- Cross-board totals in hero stats bar

### Priority 5 — Serial Search
Wire `dewi-assets-search.html` and `dewi-assets-scan.html`:
- Query `assets` by `serial_number` (case-insensitive, partial match)
- Return full chain: school → cart → slot → student username
- School admin: search within their school only
- Board admin: search across all schools in board

### Priority 6 — Fleet Health
Wire `dewi-assets-fleet.html`:
- Group all devices by AUE year from `assets.notes.aue`
- Build bar chart data: count per year 2025–2031
- Colour: expired/this year = red · within 24mo = amber · healthy = green

### Priority 7 — Reports (CSV export)
Wire export buttons in `dewi-assets-reports.html`:
- Full inventory CSV: all assets fields + cart name + school
- Expiring this year CSV: filtered by AUE year = current year
- Unassigned devices CSV: assets with no matching student slot assignment
- PDF generation: stub with `window.print()` for now — flag for Phase 2

### Priority 8 — Settings
Wire `dewi-assets-settings.html`:
- Board profile form: load from + save to `admin_accounts` table
- Schools list: load from + manage `board_schools` table
- Admin access table: load from `admin_accounts` + `admin_invites`
- Invite flow: insert into `admin_invites`, send email via Supabase Auth
- Danger zone: export all data as CSV

---

## 13. Device Type Detection

When displaying devices, type is auto-detected from the model string if not explicitly stored:

```js
function detectDeviceType(model) {
  if (!model) return 'Device';
  const m = model.toLowerCase();
  if (m.includes('chromebook')) return 'Chromebook';
  if (m.includes('ipad')) return 'iPad';
  if (m.includes('macbook')) return 'MacBook';
  if (m.includes('surface')) return 'Surface';
  return 'Laptop';
}
```

---

## 14. AUE Badge Logic

```js
function aueStatus(aueString) {
  // aueString format: 'YYYY-MM' e.g. '2029-06'
  if (!aueString || aueString === 'Unknown') 
    return { label: 'Unknown', cls: 'health-unknown' };
  const aueDate = new Date(aueString + '-01');
  const now = new Date();
  const monthsRemaining = 
    (aueDate.getFullYear() - now.getFullYear()) * 12 + 
    (aueDate.getMonth() - now.getMonth());
  if (monthsRemaining <= 0)  
    return { label: 'Expired', cls: 'health-bad' };
  if (monthsRemaining <= 12) 
    return { label: `${monthsRemaining}mo left`, cls: 'health-warn' };
  if (monthsRemaining <= 24) 
    return { label: `${Math.round(monthsRemaining/12, 1)}yr left`, cls: 'health-warn-lt' };
  return { label: `${Math.round(monthsRemaining/12)}yr left`, cls: 'health-good' };
}
```

---

## 15. Pricing (for settings page and any billing UI)

| Plan | Price | Scope |
|---|---|---|
| School Plan | $299 CAD/year | One school, all assets, all staff, unlimited items |
| District Plan | $2,500–$5,000 CAD/year | All schools in board, consolidated reporting |
| Setup & onboarding | $199 one-time (optional) | For district-level rollouts |

---

## 16. Deployment Notes

- **Hosting:** Cloudflare Pages (not Netlify — that's the teacher app)
- **Domain:** TBD — will be set up separately from `getdewi.ca`
- **GitHub repo:** Create new repo under `orbidium-netizen` for Dewi Assets
- **macOS deploy gotcha:** Always run `xattr -c` on files before deploying — macOS extended attributes cause Firebase/Cloudflare CLI deploy failures
- **Supabase RLS rules for named databases:** Deploy via Supabase Console UI, not CLI
- **All output files must be complete and deployable** — never diffs or snippets

---

## 17. What NOT to Build Yet

These are documented for Phase 2 — do not build in this session:

- AI photo scanning (photograph a device → AI identifies it) — Claude API feature
- Consumables tracking (photocopier paper, etc.) — Phase 3
- Dewi Assets label printing for non-serialised items — Phase 2
- Inter-school device transfer logging — Phase 2
- PDF report generation (real PDFs) — stub with window.print() for now
- Mobile app — browser only for now
- Dewi Assets public marketing/landing page

---

## 18. Session Goal

By the end of this Claude Code session, the following should be working with real Supabase data:

1. ✅ Admin can sign in with email/password and land on the correct dashboard
2. ✅ School dashboard shows real cart and device data for their school
3. ✅ Board dashboard shows real aggregated data across all schools
4. ✅ Serial search finds a real device and shows its full chain of custody
5. ✅ CSV exports produce real data files
6. ✅ Settings page saves board profile changes to Supabase
7. ✅ Admin invite flow sends an invite and creates a pending record

Everything else (fleet health chart, reports PDFs, label printing) can be wired with real data structure but stubbed UI where needed.

---

## 19. Test Data

To test the admin flow before real schools are onboarded:

1. Create a board admin account manually in Supabase Auth
2. Insert a row into `admin_accounts`: `{ id: <auth_uid>, email: 'orbidium@gmail.com', role: 'board', board: 'Test Board' }`
3. Insert a row into `board_schools`: `{ board_id: <admin_uid>, school_name: 'Sir John A. Macdonald', city: 'Bedford' }`
4. The existing teacher cart data (from textbook.html testing) should appear under that school automatically once the `school` field on `carts` matches `board_schools.school_name`

---

*End of handoff document. Questions → bring back to the main Dewi chat.*
