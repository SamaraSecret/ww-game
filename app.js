'use strict';
(function () {
  const cfg = window.WW_CONFIG;
  const sb = window.supabase.createClient(cfg.url, cfg.key, { auth: { persistSession: false, autoRefreshToken: false } });
  const $ = (id) => document.getElementById(id);
  const mem = { ls: {}, ss: {} };
  const wrap = (which) => ({
    get(k) {
      try { return (which === 'ss' ? sessionStorage : localStorage).getItem(k); }
      catch (e) { return mem[which][k] || null; }
    },
    set(k, v) {
      try { (which === 'ss' ? sessionStorage : localStorage).setItem(k, v); }
      catch (e) { mem[which][k] = v; }
    },
    del(k) {
      try { (which === 'ss' ? sessionStorage : localStorage).removeItem(k); }
      catch (e) { delete mem[which][k]; }
    }
  });
  const ls = wrap('ls');
  const ss = wrap('ss');
  function readToken() { return ss.get('ww_token') || ls.get('ww_token'); }
  function writeToken(tok, isAdmin) {
    if (isAdmin) { ss.set('ww_token', tok); ls.del('ww_token'); }
    else { ls.set('ww_token', tok); ss.del('ww_token'); }
  }
  function clearToken() { ss.del('ww_token'); ls.del('ww_token'); }
  let token = readToken();
  let device = ls.get('ww_device');
  if (!device || !/^[0-9a-f]{32}$/.test(device)) {
    const b = new Uint8Array(16); crypto.getRandomValues(b);
    device = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
    ls.set('ww_device', device);
  }
  let me = null;
  let timers = [];

  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      const v = attrs[k];
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (k === 'text') el.textContent = v;
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const c of kids.flat()) {
      if (c == null || c === false) continue;
      el.appendChild(typeof c === 'object' ? c : document.createTextNode(String(c)));
    }
    return el;
  }
  const money = (n) => '$' + Number(n || 0).toLocaleString('en-US');
  const num = (n) => Number(n || 0).toLocaleString('en-US', { maximumFractionDigits: 2 });
  const when = (t) => { const d = new Date(t); return d.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); };
  const mmss = (s) => { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
  const cd = (s) => (!s ? 'Ready' : mmss(s));
  const who = (p) => (p && (p.is_admin || p.staff) ? 'The Boss' : (p && p.username) || '');
  const myName = () => (me && me.is_admin ? 'The Boss' : (me && me.username) || '');

  function toast(msg, err) {
    const t = $('toast'); t.textContent = msg; t.className = 'toast' + (err ? ' err' : '');
    clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.add('hidden'), 4000);
  }

  async function call(fn, args) {
    const { data, error } = await sb.rpc(fn, Object.assign({ p_token: token }, args || {}));
    if (error) {
      const m = error.message || 'Request failed';
      if (/Session expired|Not logged in|banned/i.test(m) && fn !== 'login') { logoutLocal(m); }
      throw new Error(m);
    }
    if (data && data.me) setMe(data.me);
    return data;
  }
  async function act(fn, args, after) {
    try {
      const d = await call(fn, args);
      if (d && d.reauth) { logoutLocal(d.message || 'Please log in again.'); return d; }
      if (d && d.message) toast(d.message);
      if (after) await after(d);
      return d;
    } catch (e) { toast(e.message, true); return null; }
  }

  let authMode = 'login';
  function setAuthMode(m) {
    authMode = m;
    ['login', 'register'].forEach((x) => $('tab-' + x).classList.toggle('active', x === m));
    $('auth-submit').textContent = m === 'register' ? 'Register' : 'Log in';
    $('auth-hint').textContent = m === 'register'
      ? 'Pick a username (3-16 letters, numbers, _) and a password (8+ characters, not a common one).'
      : 'Welcome back.';
    $('auth-pass').setAttribute('autocomplete', m === 'register' ? 'new-password' : 'current-password');
    $('auth-msg').textContent = '';
  }
  ['login', 'register'].forEach((m) => $('tab-' + m).addEventListener('click', () => setAuthMode(m)));
  $('auth-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const u = $('auth-user').value.trim(), p = $('auth-pass').value;
    const msg = $('auth-msg'); msg.className = 'msg'; msg.textContent = 'Please wait...';
    $('auth-submit').disabled = true;
    try {
      const { data, error } = await sb.rpc(authMode === 'register' ? 'register' : 'login', { p_username: u, p_password: p, p_device: device });
      if (error) throw new Error(error.message);
      if (data.error) throw new Error(data.error);
      token = data.token; writeToken(token, !!data.is_admin);
      const m = await call('get_me'); setMe(m);
      $('auth-pass').value = '';
      startGame('home');
    } catch (err) { msg.textContent = err.message; }
    finally { $('auth-submit').disabled = false; }
  });

  function logoutLocal(reason) {
    token = null; me = null; clearToken();
    timers.forEach(clearInterval); timers = [];
    $('game').classList.add('hidden'); $('auth').classList.remove('hidden');
    setAuthMode('login');
    if (reason) { $('auth-msg').className = 'msg'; $('auth-msg').textContent = reason; }
  }

  function setBar(id, v, max) { $(id).style.width = Math.max(0, Math.min(100, (v / max) * 100)) + '%'; }
  function setMe(m) {
    me = m; me._at = Date.now();
    if (token) writeToken(token, !!m.is_admin);
    const name = myName();
    $('sb-name').textContent = name; $('sb-rank').textContent = m.rank;
    $('sb-level').textContent = m.level;
    $('sb-dirty').textContent = money(m.dirty != null ? m.dirty : m.cash);
    $('sb-clean').textContent = money(m.clean);
    const pts = $('sb-pts'); if (pts) pts.textContent = num(m.stat_points);
    const st = $('sb-status'); st.textContent = m.status; st.className = 'status-' + m.status;
    $('top-user').textContent = name + ' · Lv ' + m.level;
    setBar('sb-energy', m.energy, m.max_energy); setBar('sb-nerve', m.nerve, m.max_nerve);
    setBar('sb-hp', m.hp, m.max_hp);
    const atCap = m.max_level && m.level >= m.max_level;
    if (atCap) { setBar('sb-xp', 1, 1); $('sb-xp-t').textContent = 'MAX'; }
    else { setBar('sb-xp', m.xp - m.xp_prev, m.xp_next - m.xp_prev); $('sb-xp-t').textContent = num(m.xp) + ' / ' + num(m.xp_next); }
    $('sb-hp-t').textContent = m.hp + ' / ' + m.max_hp;
    updateTimers();
    renderNav();
  }
  function updateTimers() {
    if (!me) return;
    const el = (Date.now() - me._at) / 1000;
    $('sb-energy-t').textContent = me.energy + ' / ' + me.max_energy + (me.energy_next != null ? ' (+5 in ' + mmss(me.energy_next - el) + ')' : '');
    $('sb-nerve-t').textContent = me.nerve + ' / ' + me.max_nerve + (me.nerve_next != null ? ' (+1 in ' + mmss(me.nerve_next - el) + ')' : '');
    if ((me.energy_next != null && me.energy_next - el <= 0) || (me.nerve_next != null && me.nerve_next - el <= 0)) {
      if (!updateTimers._busy) { updateTimers._busy = true; refreshMe().finally(() => { updateTimers._busy = false; }); }
    }
  }
  async function refreshMe() { try { setMe(await call('get_me')); } catch (e) { /* handled */ } }

  const pages = [
    ['home', 'Home'], ['yard', 'The Yard'], ['crimes', 'Crimes'], ['streets', 'The Streets'],
    ['crew', 'Crew'], ['cartel', 'Cartel'], ['garage', 'Garage'], ['fronts', 'Fronts'],
    ['hospital', 'Hospital & Jail'], ['market', 'Black Market'], ['bank', 'Bank'],
    ['bounties', 'Bounties'], ['players', 'Directory'], ['leaderboards', 'Leaderboards'],
    ['events', 'Events'], ['chat', 'The Wire'], ['settings', 'Security']
  ];
  function renderNav() {
    const nav = $('nav'); nav.textContent = '';
    const cur = (location.hash.slice(1) || 'home').split('/')[0];
    const list = pages.slice(); if (me && me.is_admin) list.push(['admin', 'Admin Panel']);
    for (const [k, label] of list) {
      nav.appendChild(h('a', { href: '#' + k, class: cur === k ? 'active' : null }, label,
        k === 'events' && me && me.unread > 0 ? h('span', { class: 'badge' }, me.unread) : null));
    }
    nav.appendChild(h('a', { onclick: async () => { await sb.rpc('logout', { p_token: token }); logoutLocal('Logged out.'); } }, 'Log out'));
  }
  $('menu-btn').addEventListener('click', () => $('sidebar').classList.toggle('open'));

  let pageTimer = null;
  async function route() {
    if (!token) return;
    $('sidebar').classList.remove('open');
    if (pageTimer) { clearInterval(pageTimer); pageTimer = null; }
    const [page, arg] = (location.hash.slice(1) || 'home').split('/');
    renderNav();
    const host = $('main'); host.textContent = '';
    const main = h('div'); host.appendChild(main);
    const fn = views[page] || views.home;
    try { await fn(main, arg); } catch (e) { main.appendChild(h('div', { class: 'notice red' }, e.message)); }
  }
  window.addEventListener('hashchange', route);
  const go = (p) => { if (location.hash === '#' + p) route(); else location.hash = p; };

  function statusNotice(main) {
    if (!me) return;
    if (me.status === 'Hospital') main.appendChild(h('div', { class: 'notice red' }, 'You are in the hospital until ' + when(me.hospital_until) + '. ', h('a', { href: '#hospital' }, 'Go to the hospital')));
    if (me.status === 'Jail') main.appendChild(h('div', { class: 'notice red' }, 'You are in jail until ' + when(me.jail_until) + '. ', h('a', { href: '#hospital' }, 'Pay bail')));
  }
  function playerLink(p) { return h('a', { href: '#profile/' + p.id }, who(p) || p.username); }

  const ITEM_ART = new Set([
    'brass-knuckles','folding-blade','lead-pipe','hardwood-bat','crowbar','snub-revolver','pocket-pistol',
    'service-pistol','sawed-off','pump-shotgun','machine-pistol','street-smg','hunting-rifle','short-carbine',
    'silent-pistol','riot-shotgun','marksman-rifle','automatic-rifle','long-rifle','heavy-custom',
    'cloth-coat','leather-jacket','stab-vest','motorcycle-jacket','trench-coat','ballistic-vest',
    'armored-overcoat','tactical-rig',
    'beater-sedan','compact-hatch','city-taxi','pickup-truck','street-motorcycle','muscle-coupe','panel-van',
    'family-suv','luxury-sedan','tow-truck','box-truck','stretch-limo','sports-bike','getaway-coupe',
    'classic-coupe','work-boat','sports-coupe','night-lowrider','armored-suv','exotic',
    'coin-laundry','liquor-store','corner-diner','pawn-shop','car-wash','roadside-motel','nightclub',
    'warehouse','construction-front','social-club','molotovs','pipe-bombs'
  ]);
  function itemIcon(slug, name, small) {
    const s = (slug && /^[a-z0-9-]+$/.test(slug)) ? slug : 'unknown';
    const art = ITEM_ART.has(s);
    const px = small ? '32' : '80';
    return h('img', {
      class: 'item-icon' + (small ? ' sm' : ''),
      src: art ? ('assets/items/' + s + '.webp') : ('assets/icons/' + s + '.svg'),
      alt: name || '',
      width: px,
      height: px,
      loading: 'lazy',
      decoding: 'async',
      onerror: art ? function onItemArtError() {
        this.removeEventListener('error', onItemArtError);
        this.setAttribute('src', 'assets/icons/' + s + '.svg');
      } : null
    });
  }
  function itemCell(icon, name, extra, desc) {
    return h('div', { class: 'item-cell' }, itemIcon(icon, name),
      h('div', { class: 'meta' }, h('b', null, name), extra || null, desc ? h('div', { class: 'muted small' }, desc) : null));
  }

  async function fight(id, out) {
    out.textContent = '';
    const d = await act('attack', { p_target: id });
    if (!d) return;
    if (d.log) {
      const box = h('div', { class: 'log' });
      (d.log || []).forEach((line) => box.appendChild(h('div', null, line)));
      out.appendChild(box);
    }
  }

  const PATHS = {
    enforcer: { label: 'Enforcer', blurb: 'Hits harder on the street.', actions: [
      ['stand', 'Stand Tall (15 energy)', 'The next fight hits you softer for 10 minutes.'],
      ['shake', 'Shake Down (20 energy)', 'Lean on the block for dirty cash.']
    ]},
    hustler: { label: 'Hustler', blurb: 'Crimes pay more. Fronts and the chop shop keep a smaller cut.', actions: [
      ['hustle', 'Hustle (15 energy)', 'Turn a short scheme into dirty cash.'],
      ['flip', 'Flip (15 energy)', 'Turn a short pile into clean cash.']
    ]},
    fixer: { label: 'Fixer', blurb: 'Jobs go smoother. Jail and bail sit lighter on you.', actions: [
      ['grease', 'Grease Palms (15 energy)', 'Your next jobs are more likely to land for 15 minutes.'],
      ['strings', 'Pull Strings', 'Walk out of jail if you are locked up.']
    ]},
    ghost: { label: 'Ghost', blurb: 'A quieter kind of violence. Hospital hits land more often.', actions: [
      ['mark', 'Mark (15 energy)', 'The next fight hits harder and their armor matters less.'],
      ['vanish', 'Vanish', 'Slip out of the hospital without paying.']
    ]}
  };

  const views = {};

  views.home = async (main) => {
    const m = await call('get_me'); setMe(m);
    main.appendChild(h('img', { class: 'home-hero', src: 'assets/brand/banner.webp', alt: 'A white rose and a fedora on a rainy night street overlooking a dark city', width: '960', height: '540' }));
    main.appendChild(h('h2', null, 'Grayhaven'));
    if (m.announcement) main.appendChild(h('div', { class: 'notice' }, h('b', null, 'Word from The Boss: '), m.announcement.message));
    statusNotice(main);
    main.appendChild(h('div', { class: 'grid' },
      h('div', { class: 'panel' }, h('h3', null, 'You'), h('div', { class: 'kv' },
        h('span', null, 'Name'), h('span', null, myName()), h('span', null, 'Rank'), h('span', null, m.rank),
        h('span', null, 'Level'), h('span', null, m.level),
        h('span', null, 'Cartel'), h('span', null, m.faction ? m.faction.name + ' [' + m.faction.tag + ']' : 'None'),
        h('span', null, 'Crew'), h('a', { href: '#crew' }, (m.crew_class || m.force_class) + ' · ' + num(m.troops) + ' crew'),
        h('span', null, 'Path'), h('span', null, m.specialization ? PATHS[m.specialization].label : (m.level >= 15 ? 'Unchosen' : 'Opens at level 15')),
        h('span', null, 'Record'), h('span', null, m.wins + ' wins / ' + m.losses + ' losses'),
        h('span', null, 'Crimes'), h('span', null, num(m.crimes_done) + ' completed'))),
      h('div', { class: 'panel' }, h('h3', null, 'Cash'), h('div', { class: 'kv' },
        h('span', null, 'Dirty'), h('span', { class: 'money' }, money(m.dirty != null ? m.dirty : m.cash)),
        h('span', null, 'Clean'), h('span', { class: 'money' }, money(m.clean)),
        h('span', null, 'Bank'), h('span', { class: 'money' }, money(m.bank)),
        h('span', null, 'Swiss'), h('span', { class: 'money' }, money(m.swiss)))),
      h('div', { class: 'panel' }, h('h3', null, 'Stats'), h('div', { class: 'kv' },
        h('span', null, 'Strength'), h('span', null, num(m.str)), h('span', null, 'Defense'), h('span', null, num(m.def)),
        h('span', null, 'Speed'), h('span', null, num(m.spd)), h('span', null, 'Dexterity'), h('span', null, num(m.dex)),
        h('span', null, 'Total'), h('b', null, num(m.total)),
        h('span', null, 'Unspent points'), h('span', null, num(m.stat_points), ' ', h('a', { href: '#yard' }, 'spend →')))),
      h('div', { class: 'panel' }, h('h3', null, 'Equipment'), h('div', { class: 'kv' },
        h('span', null, 'Weapon'), h('span', { class: 'eq-line' }, itemIcon(m.weapon ? m.weapon.icon : 'fists', m.weapon ? m.weapon.name : 'Bare fists', true),
          m.weapon ? m.weapon.name + ' (+' + m.weapon.power + ')' : 'Bare fists'),
        h('span', null, 'Armor'), h('span', { class: 'eq-line' }, m.armor ? itemIcon(m.armor.icon, m.armor.name, true) : null,
          m.armor ? m.armor.name + ' (+' + m.armor.power + ')' : 'None')))));
    if (m.recent_events && m.recent_events.length) {
      const p = h('div', { class: 'panel' }, h('h3', null, 'Recent events'));
      m.recent_events.forEach((e) => p.appendChild(h('div', { class: 'ev' }, h('div', { class: 't' }, when(e.created_at) + ' · ' + e.kind), e.message)));
      main.appendChild(p);
    }
    main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Path'), pathPanel(m)));
  };

  function pathPanel(m) {
    const box = h('div');
    if (m.level < 15 && !m.specialization) {
      box.appendChild(h('p', { class: 'muted' }, 'At level 15 you choose a path: Enforcer, Hustler, Fixer or Ghost. The choice is permanent.'));
      return box;
    }
    if (!m.specialization) {
      box.appendChild(h('p', { class: 'muted' }, 'Choose once. Each path has a passive edge and two moves (30 minute cooldown).'));
      const grid = h('div', { class: 'grid' });
      Object.keys(PATHS).forEach((k) => {
        const p = PATHS[k];
        grid.appendChild(h('div', { class: 'panel' }, h('h3', null, p.label), h('p', { class: 'muted small' }, p.blurb),
          h('button', { class: 'btn primary', onclick: () => act('choose_path', { p_spec: k }, () => go('home')) }, 'Become a ' + p.label)));
      });
      box.appendChild(grid);
      return box;
    }
    const p = PATHS[m.specialization];
    box.appendChild(h('p', null, 'You walk the ', h('b', null, p.label), ' path. ', p.blurb));
    if (m.path_buff) box.appendChild(h('p', { class: 'muted' }, 'Active: ' + m.path_buff + (m.path_buff_until ? ' until ' + when(m.path_buff_until) : '')));
    const row = h('div', { class: 'inline' });
    p.actions.forEach(([id, label, hint]) => {
      row.appendChild(h('button', { class: 'btn', title: hint, onclick: () => act('path_action', { p_action: id }, () => go('home')) }, label));
    });
    box.appendChild(row);
    return box;
  }

  views.yard = async (main) => {
    const m = await call('get_me'); setMe(m);
    main.appendChild(h('h2', null, 'The Yard'));
    statusNotice(main);
    main.appendChild(h('p', { class: 'muted' }, 'Train a stat (1 energy each, up to 20 times) or spend the 5 points you gain each level.'));
    const stats = [['str', 'Strength'], ['def', 'Defense'], ['spd', 'Speed'], ['dex', 'Dexterity']];
    const times = h('select', null, [1, 5, 10, 20].map((n) => h('option', { value: String(n) }, n + ' times')));
    const grid = h('div', { class: 'grid' });
    stats.forEach(([k, label]) => {
      grid.appendChild(h('div', { class: 'panel' }, h('h3', null, label), h('div', { class: 'stat-big' }, num(m[k])),
        h('button', { class: 'btn primary mt8', onclick: () => act('train', { p_stat: k, p_times: parseInt(times.value, 10) }, () => go('yard')) }, 'Train')));
    });
    main.appendChild(h('div', { class: 'panel inline' }, h('span', { class: 'muted' }, 'Reps:'), times));
    main.appendChild(grid);
    if (m.stat_points > 0) {
      const ins = {};
      const row = h('div', { class: 'inline' });
      stats.forEach(([k, label]) => {
        ins[k] = h('input', { type: 'number', min: '0', placeholder: label, class: 'mw90' });
        row.appendChild(ins[k]);
      });
      row.appendChild(h('button', { class: 'btn primary', onclick: () => act('spend_stats', {
        p_str: parseInt(ins.str.value, 10) || 0, p_def: parseInt(ins.def.value, 10) || 0,
        p_spd: parseInt(ins.spd.value, 10) || 0, p_dex: parseInt(ins.dex.value, 10) || 0
      }, () => go('yard')) }, 'Spend points (' + num(m.stat_points) + ')'));
      main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Spend stat points'), row));
    }
  };

  views.crimes = async (main) => {
    main.appendChild(h('h2', null, 'Crimes'));
    statusNotice(main);
    main.appendChild(h('p', { class: 'muted' }, 'Nerve jobs around Grayhaven. Failure can land you in jail — or the hospital.'));
    const list = await call('list_crimes');
    const tb = h('tbody');
    list.forEach((c) => tb.appendChild(h('tr', null,
      h('td', null, h('b', null, c.name), h('div', { class: 'muted small' }, c.description)),
      h('td', null, c.nerve_cost), h('td', null, 'Lv ' + c.min_level),
      h('td', null, c.chance + '%'),
      h('td', { class: 'money' }, money(c.cash_min) + '–' + money(c.cash_max)),
      h('td', null, h('button', { class: 'btn small primary', disabled: c.locked || me.nerve < c.nerve_cost, onclick: () => act('do_crime', { p_crime: c.id }, () => go('crimes')) }, 'Work it')))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Job', 'Nerve', 'Req.', 'Chance', 'Dirty payout', ''].map((x) => h('th', null, x)))), tb)));
  };

  views.streets = async (main) => {
    main.appendChild(h('h2', null, 'The Streets'));
    statusNotice(main);
    main.appendChild(h('p', { class: 'muted' }, 'Pick a fight (25 energy, 10 minute cooldown per target). Players below level 3 are protected. Winning a player fight can collect any bounty on them.'));
    const list = await call('list_targets');
    const out = h('div');
    const tb = h('tbody');
    if (!list.length) tb.appendChild(h('tr', null, h('td', { colspan: '6', class: 'muted' }, 'No one is on the street.')));
    list.forEach((t) => tb.appendChild(h('tr', null,
      h('td', null, playerLink(t), t.npc ? h('span', { class: 'muted small' }, ' (thug)') : null),
      h('td', null, t.level), h('td', null, t.rank),
      h('td', null, t.faction || '—'),
      h('td', { class: 'status-' + t.status }, t.status),
      h('td', null, t.protected ? h('span', { class: 'muted small' }, 'Protected')
        : (t.cooldown > 0 ? h('span', { class: 'muted small' }, 'Wait ' + mmss(t.cooldown))
          : h('button', { class: 'btn small danger', disabled: t.status !== 'Okay', onclick: () => fight(t.id, out) }, 'Fight'))))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Name', 'Lv', 'Rank', 'Cartel', 'Status', ''].map((x) => h('th', null, x)))), tb)));
    main.appendChild(out);
  };

  views.crew = async (main) => {
    main.appendChild(h('h2', null, 'Crew'));
    statusNotice(main);
    const c = await call('get_crew');
    main.appendChild(h('div', { class: 'panel' }, h('div', { class: 'kv' },
      h('span', null, 'Class'), h('span', null, c.crew_class || c.force_class),
      h('span', null, 'Crew'), h('span', null, num(c.troops) + ' / ' + num(c.max_troops) + ' (hard cap 1,000)'),
      h('span', null, 'Power'), h('span', null, c.power && c.power.power != null ? num(c.power.power) : '—'))));
    main.appendChild(h('p', { class: 'muted small' }, 'You get 2 free crew per level (up to 300). The rest are hired with dirty cash. Issued weapons go to the best crate first.'));
    main.appendChild(h('div', { class: 'panel inline' },
      c.cost10 != null ? h('button', { class: 'btn primary', onclick: () => act('recruit_crew', { p_count: 10 }, () => go('crew')) }, 'Hire 10 (' + money(c.cost10) + ')') : null,
      c.cost100 != null ? h('button', { class: 'btn', onclick: () => act('recruit_crew', { p_count: 100 }, () => go('crew')) }, 'Hire 100 (' + money(c.cost100) + ')') : null,
      h('button', { class: 'btn danger', onclick: () => { const n = parseInt(prompt('Dismiss how many?', '10'), 10); if (n > 0) act('dismiss_crew', { p_count: n }, () => go('crew')); } }, 'Dismiss')));
    const tb = h('tbody');
    (c.weapons || []).forEach((w) => tb.appendChild(h('tr', null,
      h('td', null, itemCell(w.icon, w.name, h('span', { class: 'muted small' }, '  +' + w.attack + ' atk / +' + w.defense + ' def'), w.description)),
      h('td', { class: 'money' }, money(w.price)), h('td', null, 'Lv ' + w.min_level), h('td', null, w.owned),
      h('td', { class: 'inline' },
        h('button', { class: 'btn small primary', disabled: me.level < w.min_level, onclick: () => act('buy_crew_weapon', { p_weapon: w.id, p_qty: 1 }, () => go('crew')) }, 'Buy 1'),
        w.owned > 0 ? h('button', { class: 'btn small danger', onclick: () => act('sell_crew_weapon', { p_weapon: w.id, p_qty: 1 }, () => go('crew')) }, 'Sell 1') : null))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Crew weapons'), h('table', null,
      h('thead', null, h('tr', null, ['Crate', 'Price', 'Req.', 'Owned', ''].map((x) => h('th', null, x)))), tb)));
  };

  views.cartel = async (main, id) => {
    if (id) return cartelDetail(main, parseInt(id, 10));
    main.appendChild(h('h2', null, 'Cartels'));
    if (me.faction) main.appendChild(h('p', null, 'You are in ', h('a', { href: '#cartel/' + me.faction.id }, me.faction.name + ' [' + me.faction.tag + ']'), '.'));
    const list = await call('list_cartels');
    if (!me.faction) {
      const name = h('input', { placeholder: 'Cartel name (3-24)', maxlength: '24' });
      const tag = h('input', { placeholder: 'Tag (2-5)', maxlength: '5', class: 'mw90' });
      const desc = h('input', { placeholder: 'Short description', maxlength: '300' });
      main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Found a cartel'),
        h('p', { class: 'muted small' }, 'Costs $10,000 dirty cash.'),
        h('div', { class: 'inline' }, name, tag, desc,
          h('button', { class: 'btn primary', onclick: () => act('create_cartel', { p_name: name.value, p_tag: tag.value, p_description: desc.value }, async (d) => { await refreshMe(); if (d && d.id) go('cartel/' + d.id); else go('cartel'); }) }, 'Found'))));
    }
    const tb = h('tbody');
    if (!list.length) tb.appendChild(h('tr', null, h('td', { colspan: '6', class: 'muted' }, 'No cartels yet.')));
    list.forEach((f) => tb.appendChild(h('tr', null,
      h('td', null, h('a', { href: '#cartel/' + f.id }, f.name + ' [' + f.tag + ']')),
      h('td', null, f.leader), h('td', null, f.members), h('td', null, f.class), h('td', null, f.districts),
      h('td', null, !me.faction ? h('button', { class: 'btn small primary', onclick: () => act('join_cartel', { p_cartel: f.id }, () => refreshMe().then(() => go('cartel/' + f.id))) }, 'Join') : null))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Cartel', 'Leader', 'Members', 'Class', 'Districts', ''].map((x) => h('th', null, x)))), tb)));
    await turfPanel(main);
  };

  async function cartelDetail(main, cid) {
    const f = await call('get_cartel', { p_cartel: cid });
    main.appendChild(h('h2', null, f.name + ' [' + f.tag + ']'));
    if (f.description) main.appendChild(h('div', { class: 'panel' }, f.description));
    const inIt = me.faction && me.faction.id === f.id;
    main.appendChild(h('div', { class: 'inline mb10' },
      !me.faction ? h('button', { class: 'btn primary', onclick: () => act('join_cartel', { p_cartel: f.id }, () => refreshMe().then(() => go('cartel/' + f.id))) }, 'Join this cartel') : null,
      inIt ? h('button', { class: 'btn danger', onclick: () => { if (confirm('Leave ' + f.name + '?')) act('leave_cartel', null, () => refreshMe().then(() => go('cartel'))); } }, 'Leave cartel') : null,
      h('a', { href: '#cartel' }, 'All cartels')));
    if (inIt) {
      main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Vault'), h('div', { class: 'kv' },
        h('span', null, 'Dirty'), h('span', { class: 'money' }, money(f.vault_dirty)),
        h('span', null, 'Clean'), h('span', { class: 'money' }, money(f.vault_clean))),
        vaultForm(f)));
    }
    if (f.districts && f.districts.length) {
      main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Turf'),
        ...f.districts.map((d) => h('div', { class: 'ev' }, d.name, ' · tribute value ', money(d.wealth)))));
    }
    const tb = h('tbody');
    (f.members || []).forEach((p) => tb.appendChild(h('tr', null,
      h('td', null, playerLink(p), p.is_leader ? h('span', { class: 'money small' }, ' (Leader)') : null),
      h('td', null, p.level), h('td', null, p.rank), h('td', { class: 'status-' + p.status }, p.status))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Members'), h('table', null,
      h('thead', null, h('tr', null, ['Name', 'Lv', 'Rank', 'Status'].map((x) => h('th', null, x)))), tb)));
    if (inIt) await raidPanel(main);
  }

  function vaultForm(f) {
    const amt = h('input', { type: 'number', min: '1', placeholder: 'Amount', class: 'mw130' });
    const kind = h('select', { class: 'mw120' }, h('option', { value: 'dirty' }, 'Dirty'), h('option', { value: 'clean' }, 'Clean'));
    return h('div', { class: 'inline mt8' }, amt, kind,
      h('button', { class: 'btn', onclick: () => act('cartel_vault', { p_kind: kind.value, p_amount: parseInt(amt.value, 10), p_dir: 'deposit' }, () => go('cartel/' + f.id)) }, 'Deposit'),
      f.is_leader ? h('button', { class: 'btn danger', onclick: () => act('cartel_vault', { p_kind: kind.value, p_amount: parseInt(amt.value, 10), p_dir: 'withdraw' }, () => go('cartel/' + f.id)) }, 'Withdraw') : null);
  }

  async function turfPanel(main) {
    const list = await call('list_districts');
    const tb = h('tbody');
    list.forEach((d) => tb.appendChild(h('tr', null,
      h('td', null, h('b', null, d.name), h('div', { class: 'muted small' }, d.description)),
      h('td', { class: 'money' }, money(d.wealth)),
      h('td', null, d.holder ? (d.holder + ' [' + d.holder_tag + ']') : 'Open'),
      h('td', null, d.cooldown > 0 ? cd(d.cooldown) : 'Open'),
      h('td', { class: 'inline' },
        me.faction && me.faction.id !== d.holder_id && d.cooldown === 0
          ? h('button', { class: 'btn small danger', onclick: () => act('contest_district', { p_district: d.id }, () => go('cartel')) }, 'Contest (30 energy)') : null,
        me.faction && me.faction.leader && d.holder_id === me.faction.id && d.tribute_ready
          ? h('button', { class: 'btn small primary', onclick: () => act('collect_tribute', { p_district: d.id }, () => go('cartel')) }, 'Collect tribute') : null))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Grayhaven districts'), h('table', null,
      h('thead', null, h('tr', null, ['District', 'Tribute', 'Holder', 'Cooldown', ''].map((x) => h('th', null, x)))), tb)));
  }

  async function raidPanel(main) {
    const bosses = await call('list_raid_bosses');
    const data = await call('list_raids');
    const raids = data.raids || [];
    const open = raids.find((r) => r.status === 'open');
    const box = h('div', { class: 'panel' }, h('h3', null, 'Jobs (raids)'));
    if (!open && me.faction && me.faction.leader) {
      const sel = h('select', null, bosses.map((b) => h('option', { value: String(b.id) }, b.name + ' · lv ' + b.min_level + ' · ' + b.min_members + '+ people')));
      box.appendChild(h('div', { class: 'inline mb8' }, sel,
        h('button', { class: 'btn primary', onclick: () => act('start_raid', { p_boss: Number(sel.value) }, () => go(location.hash.slice(1))) }, 'Open a job')));
    }
    if (open) {
      box.appendChild(h('p', null, 'Open job: ', h('b', null, open.boss), ' led by ', open.leader, '.'));
      const role = h('select', { class: 'mw130' },
        h('option', { value: 'breach' }, 'Breach'), h('option', { value: 'hack' }, 'Hack'), h('option', { value: 'combat' }, 'Combat'));
      box.appendChild(h('div', { class: 'inline' }, role,
        h('button', { class: 'btn', onclick: () => act('join_raid', { p_raid: open.id, p_role: role.value }, () => go(location.hash.slice(1))) }, 'Join / set role'),
        me.id === open.leader_id ? h('button', { class: 'btn primary', onclick: () => act('commit_raid', null, () => go(location.hash.slice(1))) }, 'Commit the job') : null));
      (open.members || []).forEach((m) => box.appendChild(h('div', { class: 'ev' }, m.username + ' · ' + m.role)));
    }
    raids.filter((r) => r.status !== 'open').slice(0, 5).forEach((r) => {
      box.appendChild(h('div', { class: 'ev' }, h('div', { class: 't' }, when(r.resolved_at) + ' · ' + r.status),
        r.boss + (r.chest ? ' · vault +' + money(r.chest) : '')));
    });
    main.appendChild(box);
  }

  views.garage = async (main) => {
    main.appendChild(h('h2', null, 'Garage'));
    statusNotice(main);
    const g = await call('list_garage');
    main.appendChild(h('p', { class: 'muted' }, 'Boost a ride off the street (8 min cooldown). Tune it, chop it for scrap, or export it through the docks (6 hour cooldown). Garage holds 20 cars. ' +
      'Steal cooldown: ' + cd(g.steal_cooldown) + '. Export: ' + cd(g.export_cooldown) + '. Slots ' + g.slots + ' / ' + g.max_slots + '.'));
    const own = h('tbody');
    if (!(g.cars || []).length) own.appendChild(h('tr', null, h('td', { colspan: '5', class: 'muted' }, 'The garage is empty.')));
    (g.cars || []).forEach((c) => own.appendChild(h('tr', null,
      h('td', null, itemCell(c.icon, c.name, h('span', { class: 'muted small' }, '  Stage ' + c.tune_level + ' / 5'), c.description)),
      h('td', { class: 'money' }, money(c.chop_value)), h('td', { class: 'money' }, money(c.export_value)),
      h('td', { class: 'money' }, c.tune_level >= 5 ? 'Max' : money(c.tune_cost)),
      h('td', { class: 'inline' },
        c.tune_level < 5 ? h('button', { class: 'btn small', onclick: () => act('tune_car', { p_unit: c.id }, () => go('garage')) }, 'Tune') : null,
        h('button', { class: 'btn small danger', onclick: () => act('chop_car', { p_unit: c.id }, () => go('garage')) }, 'Chop'),
        h('button', { class: 'btn small primary', disabled: g.export_cooldown > 0, onclick: () => act('export_car', { p_unit: c.id }, () => go('garage')) }, 'Export')))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Your rides'), h('table', null,
      h('thead', null, h('tr', null, ['Car', 'Chop', 'Export', 'Tune cost', ''].map((x) => h('th', null, x)))), own)));
    const tb = h('tbody');
    (g.targets || []).forEach((v) => tb.appendChild(h('tr', null,
      h('td', null, itemCell(v.icon, v.name, null, v.description)),
      h('td', null, 'Lv ' + v.min_level), h('td', null, v.energy + ' energy'),
      h('td', null, v.chance + '%'),
      h('td', null, h('button', { class: 'btn small primary', disabled: v.locked || g.steal_cooldown > 0, onclick: () => act('steal_car', { p_vehicle: v.id }, () => go('garage')) }, 'Boost')))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'On the street'), h('table', null,
      h('thead', null, h('tr', null, ['Ride', 'Req.', 'Cost', 'Chance', ''].map((x) => h('th', null, x)))), tb)));
  };

  views.fronts = async (main) => {
    main.appendChild(h('h2', null, 'Fronts'));
    statusNotice(main);
    main.appendChild(h('p', { class: 'muted' }, 'Buy a legitimate-looking business with dirty cash. It quietly turns dirty cash into clean cash over time, keeping a fee. Catch-up is capped at 48 hours.'));
    const list = await call('list_businesses');
    const tb = h('tbody');
    list.forEach((b) => tb.appendChild(h('tr', null,
      h('td', null, itemCell(b.icon, b.name, b.owned ? h('span', { class: 'money small' }, ' (owned)') : null, b.description)),
      h('td', { class: 'money' }, money(b.price)), h('td', null, 'Lv ' + b.min_level),
      h('td', null, money(b.launder_per_hour) + '/h'),
      h('td', null, (b.fee_bps / 100).toFixed(1) + '% fee'),
      h('td', null, b.owned ? h('span', { class: 'muted' }, 'Owned') :
        h('button', { class: 'btn small primary', disabled: b.locked, onclick: () => act('buy_business', { p_business: b.id }, () => go('fronts')) }, 'Buy')))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Front', 'Price', 'Req.', 'Rate', 'Fee', ''].map((x) => h('th', null, x)))), tb)));
  };

  views.hospital = async (main) => {
    main.appendChild(h('h2', null, 'Hospital & Jail'));
    statusNotice(main);
    const row = h('div', { class: 'inline mb10' });
    if (me.status === 'Hospital') row.appendChild(h('button', { class: 'btn primary', onclick: () => act('revive', null, () => go('hospital')) }, 'Pay for treatment'));
    if (me.status === 'Jail') row.appendChild(h('button', { class: 'btn primary', onclick: () => act('pay_bail', null, () => go('hospital')) }, 'Pay bail'));
    if (row.childNodes.length) main.appendChild(row);
    const hosp = await call('hospital_list');
    const jail = await call('jail_list');
    const ht = h('tbody');
    if (!hosp.length) ht.appendChild(h('tr', null, h('td', { colspan: '4', class: 'muted' }, 'The ward is empty.')));
    hosp.forEach((p) => ht.appendChild(h('tr', null, h('td', null, playerLink(p)), h('td', null, p.level), h('td', null, when(p.until)),
      h('td', null, p.id !== me.id ? h('button', { class: 'btn small danger', onclick: () => act('hospital_hit', { p_target: p.id }, () => go('hospital')) }, 'Hit (20 energy)') : null))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Hospital'), h('table', null,
      h('thead', null, h('tr', null, ['Player', 'Lv', 'Until', ''].map((x) => h('th', null, x)))), ht)));
    const jt = h('tbody');
    if (!jail.length) jt.appendChild(h('tr', null, h('td', { colspan: '4', class: 'muted' }, 'The cells are empty.')));
    jail.forEach((p) => jt.appendChild(h('tr', null, h('td', null, playerLink(p)), h('td', null, p.level), h('td', null, when(p.until)),
      h('td', null, p.id !== me.id ? h('button', { class: 'btn small', onclick: () => act('jail_break', { p_target: p.id }, () => go('hospital')) }, 'Break out (20 energy)') : null))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, 'Jail'), h('table', null,
      h('thead', null, h('tr', null, ['Player', 'Lv', 'Until', ''].map((x) => h('th', null, x)))), jt)));
  };

  views.market = async (main) => {
    main.appendChild(h('h2', null, 'Black Market'));
    statusNotice(main);
    main.appendChild(h('p', { class: 'muted' }, 'Weapons and armor, paid in dirty cash. Items sell back for half.'));
    const items = await call('list_items');
    for (const kind of ['weapon', 'armor']) {
      const tb = h('tbody');
      items.filter((i) => i.kind === kind).forEach((i) => tb.appendChild(h('tr', null,
        h('td', null, itemCell(i.icon, i.name, i.equipped ? h('span', { class: 'money small' }, ' (equipped)') : null, i.description)),
        h('td', null, '+' + i.power), h('td', { class: 'money' }, money(i.price)), h('td', null, 'Lv ' + i.min_level), h('td', null, i.owned),
        h('td', { class: 'inline' },
          h('button', { class: 'btn small primary', disabled: me.level < i.min_level, onclick: () => act('buy_item', { p_item: i.id }, () => go('market')) }, 'Buy'),
          i.owned > 0 && !i.equipped ? h('button', { class: 'btn small', onclick: () => act('equip_item', { p_item: i.id }, () => go('market')) }, 'Equip') : null,
          i.equipped ? h('button', { class: 'btn small', onclick: () => act('unequip_item', { p_kind: kind }, () => go('market')) }, 'Unequip') : null,
          i.owned > 0 ? h('button', { class: 'btn small danger', onclick: () => act('sell_item', { p_item: i.id }, () => go('market')) }, 'Sell') : null))));
      main.appendChild(h('div', { class: 'panel table-wrap' }, h('h3', null, kind === 'weapon' ? 'Weapons' : 'Armor'), h('table', null,
        h('thead', null, h('tr', null, ['Item', 'Power', 'Price', 'Req.', 'Owned', ''].map((x) => h('th', null, x)))), tb)));
    }
  };

  views.bank = async (main) => {
    main.appendChild(h('h2', null, 'Bank'));
    const m = await call('get_me'); setMe(m);
    const swiss = await call('swiss_list');
    main.appendChild(h('p', { class: 'muted' }, 'The bank holds clean cash only. Deposits cost a 1% fee. The teller will launder dirty cash into clean for a steep cut (about 30%, less for a Hustler). Swiss accounts pay yield if you wait out the term. Early close returns the principal only.'));
    const amt = h('input', { type: 'number', min: '1', placeholder: 'Amount' });
    const val = () => parseInt(amt.value, 10);
    main.appendChild(h('div', { class: 'panel' }, h('div', { class: 'kv' },
      h('span', null, 'Dirty'), h('span', { class: 'money' }, money(m.dirty != null ? m.dirty : m.cash)),
      h('span', null, 'Clean'), h('span', { class: 'money' }, money(m.clean)),
      h('span', null, 'Bank'), h('span', { class: 'money' }, money(m.bank)))));
    main.appendChild(h('div', { class: 'panel inline' }, amt,
      h('button', { class: 'btn primary', onclick: () => act('bank_deposit', { p_amount: val() }, () => go('bank')) }, 'Deposit clean'),
      h('button', { class: 'btn', onclick: () => act('bank_withdraw', { p_amount: val() }, () => go('bank')) }, 'Withdraw'),
      h('button', { class: 'btn', onclick: () => act('bank_launder', { p_amount: val() }, () => go('bank')) }, 'Launder dirty'),
      h('button', { class: 'btn small', onclick: () => { amt.value = me.clean; } }, 'All clean'),
      h('button', { class: 'btn small', onclick: () => { amt.value = (me.dirty != null ? me.dirty : me.cash); } }, 'All dirty'),
      h('button', { class: 'btn small', onclick: () => { amt.value = me.bank; } }, 'All bank')));
    const sam = h('input', { type: 'number', min: '1000', placeholder: 'Clean amount (min $1,000)', class: 'mw200' });
    const term = h('select', { class: 'mw130' }, (swiss.terms || []).map((t) => h('option', { value: t.id }, t.label + ' · ' + (t.interest_bps / 100) + '%')));
    main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Swiss accounts (' + swiss.open + ' / ' + swiss.max_open + ')'),
      h('div', { class: 'inline mb8' }, sam, term,
        h('button', { class: 'btn primary', onclick: () => act('swiss_open', { p_amount: parseInt(sam.value, 10), p_term: term.value }, () => go('bank')) }, 'Open account')),
      ...(swiss.accounts || []).map((a) => h('div', { class: 'ev inline' },
        h('span', null, money(a.amount) + (a.ready ? ' matured, payout ' + money(a.payout) : ' matures ' + when(a.matures_at))),
        h('button', { class: 'btn small', onclick: () => act('swiss_collect', { p_account: a.id }, () => go('bank')) }, a.ready ? 'Collect' : 'Close early')))));
  };

  views.bounties = async (main) => {
    main.appendChild(h('h2', null, 'Bounties'));
    statusNotice(main);
    main.appendChild(h('p', { class: 'muted' }, 'Put dirty cash on a player\'s head (minimum $1,000). The next player who drops them on the street collects the pot.'));
    const list = await call('list_bounties');
    const tid = h('input', { type: 'number', placeholder: 'Player id', class: 'mw130' });
    const amt = h('input', { type: 'number', min: '1000', placeholder: 'Amount', class: 'mw130' });
    main.appendChild(h('div', { class: 'panel inline' }, tid, amt,
      h('button', { class: 'btn primary', onclick: () => act('place_bounty', { p_target: parseInt(tid.value, 10), p_amount: parseInt(amt.value, 10) }, () => go('bounties')) }, 'Place bounty'),
      h('span', { class: 'muted small' }, 'Use a player id from the Directory.')));
    const tb = h('tbody');
    if (!list.length) tb.appendChild(h('tr', null, h('td', { colspan: '5', class: 'muted' }, 'No open bounties.')));
    list.forEach((b) => tb.appendChild(h('tr', null,
      h('td', null, h('a', { href: '#profile/' + b.target_id }, b.username)),
      h('td', null, b.level), h('td', { class: 'status-' + b.status }, b.status),
      h('td', { class: 'money' }, money(b.total)), h('td', null, b.count))));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Target', 'Lv', 'Status', 'Pot', 'Hits'].map((x) => h('th', null, x)))), tb)));
  };

  views.players = async (main) => {
    main.appendChild(h('h2', null, 'Directory'));
    const q = h('input', { placeholder: 'Search username', maxlength: '16' });
    let page = 0;
    const tb = h('tbody');
    const load = async () => {
      const list = await call('list_players', { p_search: q.value, p_page: page });
      tb.textContent = '';
      if (!list.length) tb.appendChild(h('tr', null, h('td', { colspan: '5', class: 'muted' }, 'No players found.')));
      list.forEach((p) => tb.appendChild(h('tr', null, h('td', null, playerLink(p), p.npc ? h('span', { class: 'muted small' }, ' (thug)') : null),
        h('td', null, p.level), h('td', null, p.rank), h('td', null, p.faction ? p.faction.tag : '—'),
        h('td', { class: 'status-' + p.status }, p.status + (p.online ? ' · online' : '')))));
    };
    main.appendChild(h('div', { class: 'panel inline' }, q, h('button', { class: 'btn', onclick: () => { page = 0; load(); } }, 'Search'),
      h('button', { class: 'btn small', onclick: () => { if (page > 0) { page--; load(); } } }, '‹ Prev'),
      h('button', { class: 'btn small', onclick: () => { page++; load(); } }, 'Next ›')));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['Player', 'Lv', 'Rank', 'Cartel', 'Status'].map((x) => h('th', null, x)))), tb)));
    await load();
  };

  views.profile = async (main, id) => {
    const p = await call('get_profile', { p_player: parseInt(id, 10) });
    main.appendChild(h('h2', null, who(p) || p.username));
    main.appendChild(h('div', { class: 'panel' }, h('div', { class: 'kv' },
      h('span', null, 'Rank'), h('span', null, p.rank + (p.npc ? ' · Street thug' : '')),
      h('span', null, 'Level'), h('span', null, p.level),
      h('span', null, 'Crew class'), h('span', null, p.force),
      h('span', null, 'Cartel'), p.faction ? h('a', { href: '#cartel/' + p.faction.id }, p.faction.name + ' [' + p.faction.tag + ']') : h('span', null, 'None'),
      h('span', null, 'Status'), h('span', { class: 'status-' + p.status }, p.status + (p.online ? ' · online' : '')),
      h('span', null, 'Record'), h('span', null, p.wins + ' wins / ' + p.losses + ' losses'),
      h('span', null, 'Joined'), h('span', null, p.joined),
      h('span', null, 'Id'), h('span', null, p.id))));
    main.appendChild(h('p', { class: 'muted small' }, 'Battle stats, crew size, cash and bank balances are private.'));
    const out = h('div');
    if (p.id !== me.id && !p.staff && p.status === 'Okay' && (p.npc || p.level >= 3)) {
      main.appendChild(h('button', { class: 'btn danger', onclick: () => fight(p.id, out) }, 'Fight ' + (who(p) || p.username) + ' (25 energy)'));
    }
    if (p.id !== me.id && !p.staff && !p.npc) {
      const amt = h('input', { type: 'number', min: '1000', placeholder: 'Bounty (min $1,000)', class: 'mw200' });
      main.appendChild(h('div', { class: 'inline mt8' }, amt,
        h('button', { class: 'btn', onclick: () => act('place_bounty', { p_target: p.id, p_amount: parseInt(amt.value, 10) }, () => go('profile/' + p.id)) }, 'Place bounty')));
    }
    main.appendChild(out);
  };

  views.leaderboards = async (main, kind) => {
    kind = kind || 'level';
    main.appendChild(h('h2', null, 'Leaderboards'));
    const tabs = [['level', 'Level'], ['wins', 'Wins'], ['stats', 'Stats'], ['crew', 'Crew'], ['wealth', 'Wealth']];
    main.appendChild(h('div', { class: 'tabs' }, tabs.map(([k, l]) => h('button', { class: 'tab' + (k === kind ? ' active' : ''), onclick: () => go('leaderboards/' + k) }, l))));
    if (kind === 'stats' || kind === 'wealth' || kind === 'crew') main.appendChild(h('p', { class: 'muted small' }, 'Only the order is shown. Exact numbers are private.'));
    const list = await call('leaderboard', { p_kind: kind });
    const tb = h('tbody');
    list.forEach((p, i) => tb.appendChild(h('tr', null, h('td', null, '#' + (i + 1)), h('td', null, playerLink(p)), h('td', null, p.rank), h('td', null, p.value == null ? '—' : num(p.value)))));
    if (!list.length) tb.appendChild(h('tr', null, h('td', { colspan: '4', class: 'muted' }, 'No players yet.')));
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['#', 'Player', 'Rank', kind === 'wins' ? 'Wins' : kind === 'level' ? 'Level' : ''].map((x) => h('th', null, x)))), tb)));
  };

  views.events = async (main) => {
    main.appendChild(h('h2', null, 'Events'));
    const list = await call('get_events');
    const p = h('div', { class: 'panel' });
    if (!list.length) p.appendChild(h('p', { class: 'muted' }, 'No events yet.'));
    list.forEach((e) => p.appendChild(h('div', { class: 'ev' + (e.seen ? '' : ' unseen') }, h('div', { class: 't' }, when(e.created_at) + ' · ' + e.kind), e.message)));
    main.appendChild(p);
    me.unread = 0; renderNav();
  };

  views.chat = async (main) => {
    main.appendChild(h('h2', null, 'The Wire'));
    const box = h('div', { class: 'chat-box' });
    const input = h('input', { maxlength: '200', placeholder: 'Message (max 200 characters)' });
    let lastId = 0;
    const load = async () => {
      try {
        const list = await call('get_chat');
        const newest = list.length ? list[list.length - 1].id : 0;
        if (newest === lastId) return;
        lastId = newest; box.textContent = '';
        list.forEach((c) => box.appendChild(h('div', { class: 'chat-line' }, h('span', { class: 't' }, when(c.created_at)),
          c.player_id ? h('a', { class: 'u' + (c.staff ? ' staff' : ''), href: '#profile/' + c.player_id }, c.username + ':') : h('span', { class: 'u staff' }, c.username + ':'),
          h('span', null, c.message))));
        box.scrollTop = box.scrollHeight;
      } catch (e) { /* ignore */ }
    };
    const send = async () => { const m = input.value.trim(); if (!m) return; const ok = await act('send_chat', { p_message: m }); if (ok) { input.value = ''; load(); } };
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') send(); });
    main.appendChild(box);
    main.appendChild(h('div', { class: 'inline' }, input, h('button', { class: 'btn primary', onclick: send }, 'Send')));
    main.appendChild(h('p', { class: 'muted small' }, 'Be respectful. One message every 4 seconds. The Boss can ban abusive players.'));
    await load();
    pageTimer = setInterval(load, 5000);
  };

  views.settings = async (main) => {
    main.appendChild(h('h2', null, 'Security'));
    const o = h('input', { type: 'password', placeholder: 'Current password', autocomplete: 'current-password', minlength: '8', maxlength: '72' });
    const n = h('input', { type: 'password', placeholder: 'New password', autocomplete: 'new-password', minlength: '8', maxlength: '72' });
    const c = h('input', { type: 'password', placeholder: 'Confirm new password', autocomplete: 'new-password', minlength: '8', maxlength: '72' });
    main.appendChild(h('div', { class: 'panel' },
      h('h3', null, 'Change password'),
      h('p', { class: 'muted small' }, 'Use 8-72 characters. Do not reuse a password from another site, and avoid very common passwords. Changing your password signs other devices out. If you are The Boss, every session including this one ends and you must log in again.'),
      o, n, c,
      h('button', { class: 'btn primary mt8', onclick: () => {
        if (n.value !== c.value) { toast('The new passwords do not match.', true); return; }
        act('change_password', { p_old: o.value, p_new: n.value }, () => { o.value = ''; n.value = ''; c.value = ''; });
      } }, 'Change password')));
    main.appendChild(h('div', { class: 'panel' },
      h('h3', null, 'Sessions'),
      h('p', { class: 'muted small' }, 'Sign out on this device from the sidebar. Use the button below to end every session, including this one.'),
      h('button', { class: 'btn danger', onclick: () => { if (confirm('Sign out on every device?')) act('logout_everywhere'); } }, 'Sign out everywhere')));
    main.appendChild(h('div', { class: 'panel muted small' },
      'Your data: we store only your username, a scrambled (bcrypt) password hash and your game progress. No email address or IP address is stored. ',
      'Player sessions are kept in this browser until they expire (7 days) or you sign out. Sessions for The Boss are kept only until you close this tab, and the server ends them after 2 hours idle or 12 hours at most.'));
  };

  views.admin = async (main) => {
    if (!me.is_admin) { main.appendChild(h('div', { class: 'notice red' }, 'The Boss only.')); return; }
    main.appendChild(h('h2', null, 'Admin Panel'));
    const m0 = await call('get_me'); setMe(m0);
    const after = () => go('admin');
    const fld = (ph, v) => h('input', { type: 'number', placeholder: ph, value: v == null ? '' : String(v), class: 'mw130' });
    const sStr = fld('Strength', m0.str), sDef = fld('Defense', m0.def), sSpd = fld('Speed', m0.spd), sDex = fld('Dexterity', m0.dex), sLvl = fld('Level', m0.level);
    const gCash = fld('Dirty cash'), gTroops = fld('Crew'), gWq = fld('Qty'), gVq = fld('Qty');
    const crew = await call('get_crew');
    const garage = await call('list_garage');
    const wSel = h('select', { class: 'mw200' }, (crew.weapons || []).map((w) => h('option', { value: String(w.id) }, w.name)));
    const vSel = h('select', { class: 'mw200' }, (garage.targets || []).map((v) => h('option', { value: String(v.id) }, v.name)));
    const ord = h('input', { maxlength: '300', placeholder: 'Word from The Boss, sent to every player\'s Events inbox' });
    const val = (el) => (el.value === '' ? null : Number(el.value));
    main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Powers (your own character)'),
      h('div', { class: 'inline' },
        h('button', { class: 'btn primary', onclick: () => act('admin_power_refill', null, after) }, 'Refill energy / nerve / health'),
        h('button', { class: 'btn', onclick: () => act('admin_power_release', null, after) }, 'Instant release (hospital / jail)'),
        h('button', { class: 'btn ' + (m0.immortal ? 'danger' : ''), onclick: () => act('admin_power_toggle', { p_power: 'immortal', p_on: !m0.immortal }, after) }, 'Immortal: ' + (m0.immortal ? 'ON' : 'OFF')),
        h('button', { class: 'btn ' + (m0.god_strike ? 'danger' : ''), onclick: () => act('admin_power_toggle', { p_power: 'god_strike', p_on: !m0.god_strike }, after) }, 'God strike: ' + (m0.god_strike ? 'ON' : 'OFF'))),
      h('h3', null, 'Set stats and level'), h('p', { class: 'muted small' }, 'Levels have no ordinary cap (a safety ceiling of 1,000,000 avoids overflow). Raising your level grants any missing stat points (5 per level-up) and free crew (still capped at 300).'),
        h('div', { class: 'inline' }, sStr, sDef, sSpd, sDex, sLvl,
        h('button', { class: 'btn', onclick: () => act('admin_power_set_stats', { p_str: val(sStr), p_def: val(sDef), p_spd: val(sSpd), p_dex: val(sDex), p_level: val(sLvl) }, after) }, 'Apply')),
      h('h3', null, 'Grant yourself'), h('div', { class: 'inline' }, gCash, gTroops,
        h('button', { class: 'btn', onclick: () => act('admin_power_grant', { p_cash: val(gCash) || 0, p_troops: val(gTroops) || 0 }, after) }, 'Grant dirty cash / crew')),
      h('div', { class: 'inline mt6' }, wSel, gWq, h('button', { class: 'btn', onclick: () => act('admin_power_grant', { p_weapon: Number(wSel.value), p_weapon_qty: val(gWq) || 0 }, after) }, 'Grant crew weapons'),
        vSel, gVq, h('button', { class: 'btn', onclick: () => act('admin_power_grant', { p_vehicle: Number(vSel.value), p_vehicle_qty: val(gVq) || 0 }, after) }, 'Grant cars')),
      h('h3', null, 'Broadcast'), h('div', { class: 'inline' }, ord,
        h('button', { class: 'btn primary', onclick: () => act('admin_command_order', { p_message: ord.value }, () => { ord.value = ''; }) }, 'Send')),
      h('p', { class: 'muted small' }, 'You are hidden from The Streets, the Directory and leaderboards. Your name shows as "The Boss" in chat and in other players\' reports.')));
    const ann = h('input', { maxlength: '300', placeholder: 'Announcement shown on everyone\'s Home page (empty = clear)' });
    main.appendChild(h('div', { class: 'panel' }, h('h3', null, 'Global announcement'), h('div', { class: 'inline' }, ann,
      h('button', { class: 'btn primary', onclick: () => act('admin_announce', { p_message: ann.value }) }, 'Post'))));
    const q = h('input', { placeholder: 'Search players' });
    const tb = h('tbody');
    const detail = h('div');
    const load = async () => {
      const list = await call('admin_list_players', { p_search: q.value });
      tb.textContent = '';
      list.forEach((p) => tb.appendChild(h('tr', null, h('td', null, p.id), h('td', null, h('a', { onclick: () => showP(p.id) }, p.username), p.npc ? ' (NPC)' : '', p.is_admin ? ' (The Boss)' : ''),
        h('td', null, p.level), h('td', null, money(p.cash)), h('td', null, money(p.clean || 0)), h('td', null, money(p.bank)),
        h('td', { class: p.banned ? 'status-Hospital' : 'status-Okay' }, p.banned ? 'BANNED' : 'ok'),
        h('td', null, when(p.last_action)))));
    };
    const showP = async (id) => {
      const p = await call('admin_get_player', { p_player: id });
      detail.textContent = '';
      const amt = h('input', { type: 'number', placeholder: '+/- dirty', class: 'mw130' });
      const cln = h('input', { type: 'number', placeholder: '+/- clean', class: 'mw130' });
      const spec = h('select', { class: 'mw130' },
        h('option', { value: '' }, 'No path'),
        ...Object.keys(PATHS).map((k) => h('option', { value: k, selected: p.specialization === k }, PATHS[k].label)));
      detail.appendChild(h('div', { class: 'panel' }, h('h3', null, p.username + ' (#' + p.id + ')'), h('div', { class: 'kv' },
        h('span', null, 'Level / XP'), h('span', null, p.level + ' / ' + num(p.xp)),
        h('span', null, 'Dirty / Clean / Bank'), h('span', null, money(p.dirty != null ? p.dirty : p.cash) + ' / ' + money(p.clean) + ' / ' + money(p.bank)),
        h('span', null, 'Stats'), h('span', null, 'STR ' + num(p.str) + ' · DEF ' + num(p.def) + ' · SPD ' + num(p.spd) + ' · DEX ' + num(p.dex)),
        h('span', null, 'HP / Energy / Nerve'), h('span', null, p.hp + ' / ' + p.energy + ' / ' + p.nerve),
        h('span', null, 'Status'), h('span', null, p.status + (p.banned ? ' · BANNED' : '')),
        h('span', null, 'Path'), h('span', null, p.specialization || '—'),
        h('span', null, 'Record'), h('span', null, p.wins + 'W / ' + p.losses + 'L'), h('span', null, 'Failed logins'), h('span', null, p.failed_logins),
        h('span', null, 'Active sessions'), h('span', null, p.sessions), h('span', null, 'Created'), h('span', null, when(p.created_at))),
        h('div', { class: 'inline mt10' },
          h('button', { class: 'btn danger', onclick: () => act('admin_set_ban', { p_player: id, p_banned: !p.banned }, () => { load(); showP(id); }) }, p.banned ? 'Unban' : 'Ban'),
          amt, h('button', { class: 'btn', onclick: () => act('admin_adjust_cash', { p_player: id, p_delta: parseInt(amt.value, 10) }, () => { load(); showP(id); }) }, 'Dirty'),
          cln, h('button', { class: 'btn', onclick: () => act('admin_adjust_clean', { p_player: id, p_delta: parseInt(cln.value, 10) }, () => { load(); showP(id); }) }, 'Clean'),
          spec, h('button', { class: 'btn', onclick: () => act('admin_set_specialization', { p_player: id, p_spec: spec.value }, () => { load(); showP(id); }) }, 'Set path'),
          h('button', { class: 'btn danger', onclick: () => { if (confirm('Reset ' + p.username + ' to a fresh level 1 player?')) act('admin_reset_player', { p_player: id }, () => { load(); showP(id); }); } }, 'Reset player'))));
      detail.scrollIntoView();
    };
    main.appendChild(h('div', { class: 'panel inline' }, q, h('button', { class: 'btn', onclick: load }, 'Search')));
    main.appendChild(detail);
    main.appendChild(h('div', { class: 'panel table-wrap' }, h('table', null, h('thead', null, h('tr', null, ['#', 'Player', 'Lv', 'Dirty', 'Clean', 'Bank', 'Status', 'Last active'].map((x) => h('th', null, x)))), tb)));
    const evp = h('div', { class: 'panel' }, h('h3', null, 'Recent events (all players)'));
    main.appendChild(evp);
    await load();
    const aud = await call('admin_audit_log_list');
    const audp = h('div', { class: 'panel' }, h('h3', null, 'Admin audit log'));
    if (!aud.length) audp.appendChild(h('p', { class: 'muted' }, 'No admin actions yet.'));
    aud.slice(0, 60).forEach((l) => audp.appendChild(h('div', { class: 'ev' }, h('div', { class: 't' }, when(l.created_at) + ' · ' + (l.admin || '?') + (l.target ? ' → ' + l.target : '')),
      l.action + (l.details ? ' ' + JSON.stringify(l.details) : ''))));
    main.insertBefore(audp, evp);
    const evs = await call('admin_recent_events');
    evs.slice(0, 50).forEach((e) => evp.appendChild(h('div', { class: 'ev' }, h('div', { class: 't' }, when(e.created_at) + ' · ' + e.username + ' · ' + e.kind), e.message)));
  };

  function startGame(page) {
    $('auth').classList.add('hidden'); $('game').classList.remove('hidden');
    timers.forEach(clearInterval);
    timers = [setInterval(updateTimers, 1000), setInterval(refreshMe, 60000)];
    if (page && location.hash !== '#' + page) location.hash = page; else route();
  }
  (async function init() {
    setAuthMode('login');
    if (!token) { $('auth').classList.remove('hidden'); return; }
    try { setMe(await call('get_me')); startGame(); }
    catch (e) { logoutLocal(); }
  })();
})();
