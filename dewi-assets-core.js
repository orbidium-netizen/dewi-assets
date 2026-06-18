/* ============================================================
   DEWI ASSETS — core.js
   Shared auth gate + data layer for all Dewi Assets pages.
   Loads AFTER the inline Supabase init script in each page head
   (Safari-safe onload pattern — see handoff §4).
   Every page calls:  AssetsCore.boot({ allow:['school'|'board'], onReady(ctx){...} })
   ============================================================ */

var AssetsCore = (function () {

  /* ── Safari rules: poll for db, guard SIGNED_IN on tab focus ── */
  let sessionHandledOnLoad = false;

  function waitForDbThenAuth(cb, tries) {
    tries = tries || 0;
    if (typeof db !== 'undefined' && db) { cb(); return; }
    if (tries > 200) { console.error('Supabase never initialised'); return; }
    setTimeout(function () { waitForDbThenAuth(cb, tries + 1); }, 50);
  }

  /* ── Auth gate ── */
  async function requireAdmin(allowedRoles) {
    const { data: { session } } = await db.auth.getSession();
    if (!session) { window.location.href = 'dewi-assets-login.html'; return null; }

    const { data: profile, error } = await db
      .from('admin_accounts').select('*').eq('id', session.user.id).maybeSingle();

    if (error) { console.error('admin_accounts lookup failed:', error.message); }
    if (!profile) {
      // Authenticated but not an admin — not allowed in Dewi Assets.
      await db.auth.signOut();
      window.location.href = 'dewi-assets-login.html?e=noadmin';
      return null;
    }
    if (allowedRoles && allowedRoles.length && !allowedRoles.includes(profile.role)) {
      window.location.href = profile.role === 'board'
        ? 'dewi-assets-board.html' : 'dewi-assets-dashboard.html';
      return null;
    }

    // Guard against SIGNED_IN refiring on tab focus (Safari rule #3)
    if (!sessionHandledOnLoad) {
      sessionHandledOnLoad = true;
      db.auth.onAuthStateChange(function (event) {
        if (event === 'SIGNED_OUT') window.location.href = 'dewi-assets-login.html';
      });
    }

    // Fire-and-forget presence ping
    db.from('admin_accounts')
      .update({ last_seen: new Date().toISOString() })
      .eq('id', profile.id)
      .then(function () {}, function () {});

    return { session: session, profile: profile };
  }

  async function signOutAdmin() {
    try { await db.auth.signOut(); } catch (e) {}
    window.location.href = 'dewi-assets-login.html';
  }

  /* ── Scope: which schools can this admin see ── */
  async function getScope(profile) {
    if (profile.role === 'school') {
      return { schools: profile.school ? [profile.school] : [], boardSchools: [] };
    }
    const { data, error } = await db
      .from('board_schools').select('*')
      .eq('board_id', profile.id)
      .order('school_name');
    if (error) console.error('board_schools load failed:', error.message);
    const rows = data || [];
    return { schools: rows.map(function (s) { return s.school_name; }), boardSchools: rows };
  }

  /* ── Inventory loader: carts + assets + students, scoped ──
     Returns { carts, assets, students, byCart } with assets/students
     attached to their cart. Chunks .in() lists to stay under URL limits. */
  async function loadInventory(schools) {
    const empty = { carts: [], assets: [], students: [], byCart: {} };
    if (!schools || !schools.length) return empty;

    const { data: carts, error: ce } = await db
      .from('carts').select('*').in('school', schools)
      .order('cart_number', { ascending: true });
    if (ce) { console.error('carts load failed:', ce.message); return empty; }
    if (!carts || !carts.length) return empty;

    const ids = carts.map(function (c) { return c.id; });
    const chunks = [];
    for (let i = 0; i < ids.length; i += 80) chunks.push(ids.slice(i, i + 80));

    let assets = [], students = [];
    for (const ch of chunks) {
      const [aRes, sRes] = await Promise.all([
        db.from('assets').select('*').in('cart_id', ch).eq('asset_type', 'device'),
        db.from('students').select('*').in('cart_id', ch)
      ]);
      if (aRes.error) console.error('assets load failed:', aRes.error.message);
      if (sRes.error) console.error('students load failed:', sRes.error.message);
      assets = assets.concat(aRes.data || []);
      students = students.concat(sRes.data || []);
    }

    const byCart = {};
    carts.forEach(function (c) { byCart[c.id] = { cart: c, assets: [], students: [] }; });
    assets.forEach(function (a) { if (byCart[a.cart_id]) byCart[a.cart_id].assets.push(a); });
    students.forEach(function (s) { if (byCart[s.cart_id]) byCart[s.cart_id].students.push(s); });

    return { carts: carts, assets: assets, students: students, byCart: byCart };
  }

  /* ── Serial search across scope (case-insensitive, partial) ── */
  async function searchSerial(q, schools) {
    if (!q || !schools || !schools.length) return [];
    const { data: carts, error: ce } = await db
      .from('carts').select('*').in('school', schools);
    if (ce || !carts || !carts.length) return [];
    const cartMap = {};
    carts.forEach(function (c) { cartMap[c.id] = c; });

    const { data: hits, error: ae } = await db
      .from('assets').select('*')
      .eq('asset_type', 'device')
      .ilike('serial_number', '%' + q + '%')
      .in('cart_id', carts.map(function (c) { return c.id; }))
      .limit(10);
    if (ae) { console.error('serial search failed:', ae.message); return []; }

    const results = [];
    for (const a of (hits || [])) {
      const cart = cartMap[a.cart_id];
      let slotStudents = [];
      if (cart && a.slot_number != null) {
        const { data: studs } = await db
          .from('students').select('*')
          .eq('cart_id', a.cart_id).eq('slot_number', a.slot_number);
        slotStudents = studs || [];
      }
      results.push({ asset: a, cart: cart || null, students: slotStudents });
    }
    return results;
  }

  /* ── Handoff §13 — device type detection ── */
  function detectDeviceType(model) {
    if (!model) return 'Device';
    const m = model.toLowerCase();
    if (m.includes('chromebook')) return 'Chromebook';
    if (m.includes('ipad')) return 'iPad';
    if (m.includes('macbook')) return 'MacBook';
    if (m.includes('surface')) return 'Surface';
    return 'Laptop';
  }

  /* ── notes jsonb may arrive as object or string ── */
  function noteObj(asset) {
    if (!asset || asset.notes == null) return {};
    if (typeof asset.notes === 'object') return asset.notes;
    try { return JSON.parse(asset.notes); } catch (e) { return {}; }
  }

  /* ── Handoff §14 — AUE badge logic ── */
  function aueStatus(aueString) {
    if (!aueString || aueString === 'Unknown')
      return { label: 'Unknown', cls: 'health-unknown', months: null };
    const aueDate = new Date(aueString + '-01');
    if (isNaN(aueDate)) return { label: 'Unknown', cls: 'health-unknown', months: null };
    const now = new Date();
    const monthsRemaining =
      (aueDate.getFullYear() - now.getFullYear()) * 12 +
      (aueDate.getMonth() - now.getMonth());
    if (monthsRemaining <= 0)
      return { label: 'Expired', cls: 'health-bad', months: monthsRemaining };
    if (monthsRemaining <= 12)
      return { label: monthsRemaining + 'mo left', cls: 'health-warn', months: monthsRemaining };
    if (monthsRemaining <= 24)
      return { label: Math.round(monthsRemaining / 12) + 'yr left', cls: 'health-warn', months: monthsRemaining };
    return { label: Math.round(monthsRemaining / 12) + 'yr left', cls: 'health-good', months: monthsRemaining };
  }

  function aueYear(asset) {
    const n = noteObj(asset);
    if (!n.aue) return null;
    const y = parseInt(String(n.aue).slice(0, 4), 10);
    return isNaN(y) ? null : y;
  }

  function aueLabel(asset) {
    const n = noteObj(asset);
    if (!n.aue) return null;
    const d = new Date(n.aue + '-01');
    if (isNaN(d)) return n.aue;
    return d.toLocaleDateString('en-CA', { month: 'short', year: 'numeric' });
  }

  function condition(asset) {
    return ((asset && asset.condition) || 'good').toLowerCase();
  }

  /* A device counts as flagged if its condition is poor/damaged or its AUE has expired */
  function isFlagged(asset) {
    const c = condition(asset);
    if (c === 'poor' || c === 'damaged' || c === 'broken') return true;
    const st = aueStatus(noteObj(asset).aue);
    return st.months !== null && st.months <= 0;
  }

  function deviceAgeYears(asset) {
    if (!asset.purchase_year) return null;
    const now = new Date();
    return Math.max(0, (now.getFullYear() + now.getMonth() / 12) - asset.purchase_year);
  }

  /* ── HTML escape — every user/db string goes through this before innerHTML ── */
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /* ── CSV download with RFC-4180 quoting ── */
  function downloadCSV(filename, head, rows) {
    function cell(v) {
      v = String(v == null ? '' : v);
      return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
    }
    const lines = [head.map(cell).join(',')]
      .concat(rows.map(function (r) { return r.map(cell).join(','); }));
    const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    a.click();
    URL.revokeObjectURL(a.href);
  }

  function fmtDate(d) {
    return new Date(d).toLocaleDateString('en-CA', { day: '2-digit', month: 'short', year: 'numeric' });
  }

  function relativeTime(iso) {
    if (!iso) return '—';
    const ms = Date.now() - new Date(iso).getTime();
    const m = Math.floor(ms / 60000);
    if (m < 2) return 'Active now';
    if (m < 60) return m + ' minutes ago';
    const h = Math.floor(m / 60);
    if (h < 24) return h + (h === 1 ? ' hour ago' : ' hours ago');
    const dys = Math.floor(h / 24);
    if (dys === 1) return 'Yesterday';
    if (dys < 30) return dys + ' days ago';
    return fmtDate(iso);
  }

  /* ── Boot: the one entry point every page uses ──
     opts = { allow: ['school','board'], onReady: async function(ctx){} }
     ctx  = { session, profile, scope } */
  function boot(opts) {
    waitForDbThenAuth(function () {
      requireAdmin(opts.allow).then(function (auth) {
        if (!auth) return;
        getScope(auth.profile).then(function (scope) {
          opts.onReady({ session: auth.session, profile: auth.profile, scope: scope });
        });
      });
    });
  }

  return {
    boot: boot,
    waitForDbThenAuth: waitForDbThenAuth,
    requireAdmin: requireAdmin,
    signOutAdmin: signOutAdmin,
    getScope: getScope,
    loadInventory: loadInventory,
    searchSerial: searchSerial,
    detectDeviceType: detectDeviceType,
    noteObj: noteObj,
    aueStatus: aueStatus,
    aueYear: aueYear,
    aueLabel: aueLabel,
    condition: condition,
    isFlagged: isFlagged,
    deviceAgeYears: deviceAgeYears,
    esc: esc,
    downloadCSV: downloadCSV,
    fmtDate: fmtDate,
    relativeTime: relativeTime
  };
})();
