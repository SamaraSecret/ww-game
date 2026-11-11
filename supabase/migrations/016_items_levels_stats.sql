-- More weapons/vehicles, icon slugs, infinite levels (soft cap 1,000,000), and spendable stat points.

-- ===== Catalog: icon slugs =====
alter table game.items add column if not exists icon text not null default 'unknown';
alter table game.troop_weapons add column if not exists icon text not null default 'unknown';
alter table game.vehicles add column if not exists icon text not null default 'unknown';

update game.items set icon = case id
  when 1 then 'knife' when 2 then 'pistol' when 3 then 'bolt-rifle'
  when 4 then 'smg' when 5 then 'semi-rifle' when 6 then 'lmg'
  when 7 then 'at-launcher'
  when 101 then 'jacket' when 102 then 'helmet' when 103 then 'flak'
  when 104 then 'trench-plate' when 105 then 'ceramic' when 106 then 'assault-suit'
  else icon end;

update game.troop_weapons set icon = case id
  when 1 then 'rifles' when 2 then 'machine-guns' when 3 then 'mortars'
  when 4 then 'at-rockets' when 5 then 'flamethrowers'
  else icon end;

update game.vehicles set icon = case id
  when 1 then 'jeep' when 2 then 'armored-car' when 3 then 'light-tank'
  when 4 then 'artillery' when 5 then 'heavy-tank' when 6 then 'fighter'
  when 7 then 'bomber' when 8 then 'destroyer'
  else icon end;

-- Personal weapons (existing 1-7 stay; add 8-20)
insert into game.items (id, name, kind, power, price, min_level, description, icon) values
 (8,  'Heavy Pistol',         'weapon', 11,   2500,  2, 'A hard-hitting sidearm for close work.', 'heavy-pistol'),
 (9,  'Trench Shotgun',       'weapon', 18,   7000,  4, 'Brutal in the close confines of a trench.', 'trench-shotgun'),
 (10, 'Carbine',              'weapon', 25,  16000,  7, 'Shorter rifle, quicker to shoulder.', 'carbine'),
 (11, 'Combat Shotgun',       'weapon', 27,  20000,  8, 'Pump action with a wider pattern.', 'combat-shotgun'),
 (12, 'Cluster Grenades',     'weapon', 24,  18000,  9, 'A satchel of fragmentation grenades.', 'cluster-grenades'),
 (13, 'Marksman Rifle',       'weapon', 34,  40000, 11, 'Chosen for accuracy over volume of fire.', 'marksman'),
 (14, 'Grenade Launcher',     'weapon', 38,  55000, 13, 'Lobs explosives into cover.', 'grenade-launcher'),
 (15, 'Assault Rifle',        'weapon', 46,  95000, 16, 'Select-fire workhorse of a modern squad.', 'assault-rifle'),
 (16, 'Battle Rifle',         'weapon', 50, 125000, 17, 'Full-power cartridge, longer reach.', 'battle-rifle'),
 (17, 'Heavy Machine Gun',    'weapon', 58, 180000, 19, 'Crew-served firepower, used from the hip if you must.', 'hmg'),
 (18, 'Recoilless Rifle',     'weapon', 68, 260000, 23, 'Backblast and a hole in anything ahead.', 'recoilless'),
 (19, 'Anti-Materiel Rifle',  'weapon', 75, 350000, 26, 'Built to stop engines, not just men.', 'am-rifle'),
 (20, 'Rail Rifle',           'weapon', 90, 500000, 30, 'Experimental coil-driven longarm. Rare and loud.', 'rail-rifle')
on conflict (id) do nothing;

-- Extra armor
insert into game.items (id, name, kind, power, price, min_level, description, icon) values
 (107, 'Webbing Harness',          'armor',  4,    700,  1, 'Pouches and straps. A little padding helps.', 'webbing'),
 (108, 'Riot Shield',              'armor', 12,   8000,  6, 'A heavy shield for the front of a stack.', 'riot-shield'),
 (109, 'Composite Helmet',         'armor', 18,  28000, 10, 'Lighter than steel, stronger against fragments.', 'comp-helmet'),
 (110, 'Ballistic Plate Carrier',  'armor', 26,  70000, 16, 'Ceramic plates over vital organs.', 'plate-carrier'),
 (111, 'Bomb Suit',                'armor', 38, 180000, 24, 'Clumsy, heavy, and very hard to kill in.', 'bomb-suit'),
 (112, 'Exo Plate',                'armor', 48, 320000, 28, 'Articulated armor with powered assists.', 'exo-plate')
on conflict (id) do nothing;

-- Army weapons (existing 1-5 stay; add 6-12)
insert into game.troop_weapons (id, name, attack, defense, price, min_level, description, icon) values
 (6,  'Grenades',           2, 1,    80,  2, 'Issued fragmentation grenades.', 'grenades'),
 (7,  'Combat Shotguns',    4, 2,   280,  5, 'For clearing rooms and bunkers.', 'shotguns'),
 (8,  'Heavy Mortars',     10, 2,  1400, 12, 'Heavier tubes, longer reach.', 'heavy-mortars'),
 (9,  'Recoilless Guns',   14, 4,  2800, 18, 'Shoulder-fired anti-armor for a squad.', 'recoilless-guns'),
 (10, 'Autocannons',       18, 6,  5000, 20, 'Rapid-fire light cannon.', 'autocannons'),
 (11, 'Howitzers',         22, 5,  8000, 24, 'Field artillery in support of the line.', 'howitzers'),
 (12, 'Missile Launchers', 30, 8, 15000, 28, 'Guided anti-armor and anti-air.', 'missile-launchers')
on conflict (id) do nothing;

-- Vehicles (existing 1-8 stay; add 9-21)
insert into game.vehicles (id, name, attack, defense, price, min_level, description, icon) values
 (9,  'Motorcycle',            12,    6,    2500,  1, 'Fast scout on two wheels.', 'motorcycle'),
 (10, 'Supply Truck',          15,   25,    8000,  3, 'Hauls ammunition and a machine gun.', 'truck'),
 (11, 'Half-Track',            55,   60,   25000,  6, 'Wheels in front, tracks in back.', 'halftrack'),
 (12, 'APC',                   70,   90,   35000,  7, 'Armored ride for a full squad.', 'apc'),
 (13, 'Scout Plane',           80,   30,   50000,  9, 'Eyes in the sky, light armament.', 'scout-plane'),
 (14, 'Medium Tank',          140,  120,   90000, 11, 'The workhorse of an armored company.', 'medium-tank'),
 (15, 'Self-Propelled Gun',   180,   80,  110000, 14, 'A howitzer that can keep up with the advance.', 'spg'),
 (16, 'Transport Helicopter',  90,  110,  200000, 18, 'Moves troops and light supplies fast.', 'transport-heli'),
 (17, 'Attack Helicopter',    320,  140,  350000, 22, 'Rockets, cannons and a low, loud approach.', 'attack-heli'),
 (18, 'Jet Fighter',          420,  160,  600000, 28, 'Fast air superiority.', 'jet'),
 (19, 'Submarine',            650,  400, 1600000, 36, 'Silent hunters under the sea.', 'submarine'),
 (20, 'Cruiser',              800,  700, 2200000, 40, 'A gun line that rules the horizon.', 'cruiser'),
 (21, 'Battleship',          1100, 1000, 4000000, 45, 'The last word in naval artillery.', 'battleship')
on conflict (id) do nothing;

-- ===== Stat points =====
alter table game.players add column if not exists stat_points int not null default 0;
alter table game.players add column if not exists stat_points_granted int not null default 0;
alter table game.players drop constraint if exists players_stat_points_nonneg;
alter table game.players add constraint players_stat_points_nonneg check (stat_points >= 0);
alter table game.players drop constraint if exists players_stat_points_granted_nonneg;
alter table game.players add constraint players_stat_points_granted_nonneg check (stat_points_granted >= 0);

-- ===== Infinite levels (soft cap only to avoid overflow) =====
create or replace function game.max_level() returns int
language sql immutable set search_path = '' as $$ select 1000000 $$;

-- Cumulative XP threshold to leave level lvl (to reach lvl+1). Uses bigint math so high levels do not overflow.
create or replace function game.xp_for(lvl int) returns bigint
language sql immutable set search_path = '' as $$
  select (50::numeric * greatest(lvl, 0)::numeric * greatest(lvl, 0)::numeric)::bigint $$;

create or replace function game.max_hp(lvl int) returns int
language sql immutable set search_path = '' as $$
  select least(2000000000, 100 + (greatest(lvl, 1) - 1)::bigint * 20)::int $$;

create or replace function game.rank_title(lvl int) returns text
language sql immutable set search_path = '' as $$
  select case
    when lvl >= 500 then 'War Legend ' || ((lvl - 500) / 100 + 1)::text
    when lvl >= 250 then 'Supreme Commander ' || ((lvl - 200) / 50)::text
    when lvl >= 200 then 'Supreme Commander'
    when lvl >= 150 then 'Warlord'
    when lvl >= 100 then 'Grand Marshal'
    when lvl >= 75  then 'High Marshal'
    when lvl >= 50  then 'Field Marshal'
    when lvl >= 40  then 'General'
    when lvl >= 30  then 'Brigadier'
    when lvl >= 25  then 'Colonel'
    when lvl >= 20  then 'Major'
    when lvl >= 15  then 'Captain'
    when lvl >= 11  then 'Lieutenant'
    when lvl >= 8   then 'Sergeant'
    when lvl >= 5   then 'Corporal'
    when lvl >= 3   then 'Private'
    else 'Recruit' end $$;

-- Grant unspent stat points so total granted always equals 5 * (level - 1). Safe to call repeatedly.
create or replace function game.grant_level_stats(pid bigint, new_level int) returns int
language plpgsql security definer set search_path = '' as $$
declare granted int; need int; expected int;
begin
  if new_level is null or new_level < 1 then return 0; end if;
  expected := 5 * (new_level - 1);
  select stat_points_granted into granted from game.players where id = pid and not is_npc for update;
  if not found then return 0; end if;
  need := expected - granted;
  if need > 0 then
    update game.players set stat_points = stat_points + need, stat_points_granted = stat_points_granted + need where id = pid;
    return need;
  end if;
  return 0;
end $$;

create or replace function game.add_xp(pid bigint, amt bigint) returns int
language plpgsql security definer set search_path = '' as $$
declare lvl int; x bigint; gained int := 0; ft int := 0; sp int := 0; target int; cap int := game.max_level();
begin
  update game.players
     set xp = least(game.xp_for(cap), xp + greatest(coalesce(amt, 0), 0))
   where id = pid
   returning level, xp into lvl, x;
  if not found then return 0; end if;
  -- Closed-form: xp_for(L) = 50*L^2 is the threshold to leave L, so L = floor(sqrt(xp/50))+1.
  target := least(cap, greatest(lvl, (floor(sqrt(x::numeric / 50.0)) + 1)::int));
  gained := target - lvl;
  if gained > 0 then
    lvl := target;
    update game.players set level = lvl,
      hp = case when hospital_until is null then game.max_hp(lvl) else hp end
     where id = pid;
    ft := game.grant_level_troops(pid, gained);
    sp := game.grant_level_stats(pid, lvl);
    perform game.add_event(pid, 'promotion', format('Promoted to level %s (%s)!%s%s', lvl, game.rank_title(lvl),
      case when sp > 0 then format(' You gained %s stat points.', sp) else '' end,
      case when ft > 0 then format(' Command assigned you %s new troops.', ft) else '' end));
  end if;
  return gained;
end $$;

-- Catch up anyone stuck at the old level-100 cap whose XP already crosses the next threshold.
do $$
declare r record;
begin
  for r in select id from game.players where level < game.max_level() and xp >= game.xp_for(level) loop
    perform game.add_xp(r.id, 0);
  end loop;
end $$;

-- One-time retroactive grant for existing soldiers (based on current level, never doubles).
update game.players
   set stat_points = stat_points + greatest(0, 5 * (level - 1) - stat_points_granted),
       stat_points_granted = greatest(stat_points_granted, 5 * (level - 1))
 where not is_npc;

create or replace function game.me_json(pid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'is_admin', p.is_admin,
    'level', p.level, 'rank', game.rank_title(p.level), 'max_level', game.max_level(),
    'xp', p.xp, 'xp_prev', case when p.level = 1 then 0 else game.xp_for(p.level - 1) end,
    'xp_next', game.xp_for(p.level),
    'cash', p.cash, 'bank', p.bank,
    'hp', p.hp, 'max_hp', game.max_hp(p.level),
    'energy', p.energy, 'max_energy', 100, 'nerve', p.nerve, 'max_nerve', 10,
    'energy_next', case when p.energy >= 100 then null else greatest(0, 300 - extract(epoch from (now() - p.energy_at)))::int end,
    'nerve_next', case when p.nerve >= 10 then null else greatest(0, 300 - extract(epoch from (now() - p.nerve_at)))::int end,
    'str', p.str, 'def', p.def, 'spd', p.spd, 'dex', p.dex, 'total', p.str + p.def + p.spd + p.dex,
    'stat_points', p.stat_points, 'stat_points_granted', p.stat_points_granted, 'points_per_level', 5,
    'weapon', (select jsonb_build_object('id', i.id, 'name', i.name, 'power', i.power, 'icon', i.icon) from game.items i where i.id = p.weapon_id),
    'armor', (select jsonb_build_object('id', i.id, 'name', i.name, 'power', i.power, 'icon', i.icon) from game.items i where i.id = p.armor_id),
    'status', game.status_of(p.hospital_until, p.jail_until),
    'hospital_until', case when p.hospital_until > now() then p.hospital_until end,
    'jail_until', case when p.jail_until > now() then p.jail_until end,
    'faction', (select jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'leader', f.leader_id = p.id) from game.factions f where f.id = p.faction_id),
    'troops', p.troops, 'max_troops', game.max_troops(p.level), 'troops_cap', 1000,
    'troops_free_granted', p.troops_free_granted, 'free_troops_cap', 300,
    'immortal', p.immortal, 'god_strike', p.god_strike,
    'force_class', game.force_class((game.army_power(p.id)->>'power')::numeric),
    'wins', p.wins, 'losses', p.losses, 'missions_done', p.missions_done,
    'server_time', now()
  ) from game.players p where p.id = pid $$;

-- Spend unspent stat points on Strength / Defense / Speed / Dexterity.
create or replace function public.spend_stats(p_token text, p_str int default 0, p_def int default 0,
  p_spd int default 0, p_dex int default 0) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  pid bigint := game.auth(p_token);
  p game.players;
  s int := coalesce(p_str, 0);
  d int := coalesce(p_def, 0);
  y int := coalesce(p_spd, 0);
  x int := coalesce(p_dex, 0);
  total bigint;
begin
  if s < 0 or d < 0 or y < 0 or x < 0 then
    raise exception 'Stat points must be non-negative whole numbers.';
  end if;
  if s > 1000000000 or d > 1000000000 or y > 1000000000 or x > 1000000000 then
    raise exception 'You cannot spend that many points at once.';
  end if;
  total := s::bigint + d + y + x;
  if total <= 0 then raise exception 'Choose how many points to spend.'; end if;
  p := game.tick(pid);
  if total > p.stat_points then
    raise exception 'You only have % unspent stat point(s).', p.stat_points;
  end if;
  if p.str + s > 1e9 or p.def + d > 1e9 or p.spd + y > 1e9 or p.dex + x > 1e9 then
    raise exception 'A battle stat cannot exceed 1,000,000,000.';
  end if;
  update game.players set
    str = str + s, def = def + d, spd = spd + y, dex = dex + x,
    stat_points = stat_points - total::int
   where id = pid;
  return jsonb_build_object(
    'message', format('You assigned %s stat point(s).', total),
    'me', game.me_json(pid));
end $$;

create or replace function public.list_items(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  select * into p from game.players where id = pid;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', i.id, 'name', i.name, 'kind', i.kind, 'power', i.power, 'price', i.price,
      'min_level', i.min_level, 'description', i.description, 'icon', i.icon,
      'owned', coalesce(inv.qty, 0),
      'equipped', coalesce(i.id = p.weapon_id, false) or coalesce(i.id = p.armor_id, false)) order by i.kind desc, i.price)
    from game.items i left join game.inventory inv on inv.item_id = i.id and inv.player_id = pid), '[]'::jsonb);
end $$;

create or replace function public.get_army(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; ap jsonb; mx int;
begin
  p := game.tick(pid);
  ap := game.army_power(pid);
  mx := game.max_troops(p.level);
  return jsonb_build_object(
    'troops', p.troops, 'max_troops', mx, 'cash', p.cash, 'energy', p.energy, 'level', p.level,
    'cost10', case when p.troops + 10 <= mx then game.recruit_cost(p.troops, 10) end,
    'cost100', case when p.troops + 100 <= mx then game.recruit_cost(p.troops, 100) end,
    'power', ap, 'force_class', game.force_class((ap->>'power')::numeric),
    'weapons', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'attack', w.attack, 'defense', w.defense,
        'price', w.price, 'min_level', w.min_level, 'description', w.description, 'icon', w.icon, 'owned', coalesce(o.qty, 0)) order by w.attack)
       from game.troop_weapons w left join game.player_troop_weapons o on o.weapon_id = w.id and o.player_id = pid), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'attack', v.attack, 'defense', v.defense,
        'price', v.price, 'min_level', v.min_level, 'description', v.description, 'icon', v.icon, 'cap', game.vehicle_cap(p.level, v.min_level),
        'units', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'condition', u.condition,
              'repair_cost', ceil(v.price * 0.25 * (100 - u.condition) / 100.0)::bigint,
              'sell_value', floor(v.price * 0.4 * u.condition / 100.0)::bigint) order by u.id)
            from game.player_vehicles u where u.player_id = pid and u.vehicle_id = v.id), '[]'::jsonb)) order by v.price)
       from game.vehicles v), '[]'::jsonb));
end $$;

create or replace function public.admin_power_set_stats(p_token text, p_str numeric default null, p_def numeric default null,
  p_spd numeric default null, p_dex numeric default null, p_level int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; ft int := 0; sp int := 0;
begin
  perform game.require_admin(pid);
  if (p_str is not null and (p_str < 0 or p_str > 1e9)) or (p_def is not null and (p_def < 0 or p_def > 1e9))
     or (p_spd is not null and (p_spd < 0 or p_spd > 1e9)) or (p_dex is not null and (p_dex < 0 or p_dex > 1e9)) then
    raise exception 'Stats must be between 0 and 1,000,000,000.';
  end if;
  if p_level is not null and (p_level < 1 or p_level > game.max_level()) then
    raise exception 'Level must be 1-%.', game.max_level();
  end if;
  p := game.tick(pid);
  update game.players set
    str = coalesce(round(p_str, 2), str), def = coalesce(round(p_def, 2), def),
    spd = coalesce(round(p_spd, 2), spd), dex = coalesce(round(p_dex, 2), dex),
    level = coalesce(p_level, level),
    xp = case when p_level is null then xp when p_level = 1 then 0 else game.xp_for(p_level - 1) end,
    hp = game.max_hp(coalesce(p_level, level)), hp_at = now()
  where id = pid;
  if p_level is not null and p_level > p.level then
    ft := game.grant_level_troops(pid, p_level - p.level);
  end if;
  if p_level is not null then sp := game.grant_level_stats(pid, p_level); end if;
  perform game.audit(pid, 'power: set stats', pid, jsonb_build_object('str', p_str, 'def', p_def, 'spd', p_spd, 'dex', p_dex, 'level', p_level));
  return jsonb_build_object('message', 'Stats updated.'
    || case when ft > 0 then format(' +%s level-up troops.', ft) else '' end
    || case when sp > 0 then format(' +%s stat points.', sp) else '' end,
    'me', game.me_json(pid));
end $$;

create or replace function public.admin_reset_player(p_token text, p_player bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); t game.players;
begin
  perform game.require_admin(pid);
  t := game.tick(p_player);
  if t.is_npc then raise exception 'NPCs cannot be reset.'; end if;
  update game.players set level = 1, xp = 0, cash = 1000, bank = 0, hp = 100, energy = 100, nerve = 10,
    hp_at = now(), energy_at = now(), nerve_at = now(), str = 10, def = 10, spd = 10, dex = 10,
    weapon_id = null, armor_id = null, hospital_until = null, jail_until = null,
    wins = 0, losses = 0, missions_done = 0, troops = 0, troops_free_granted = 0,
    stat_points = 0, stat_points_granted = 0,
    immortal = false, god_strike = false where id = p_player;
  delete from game.inventory where player_id = p_player;
  delete from game.player_troop_weapons where player_id = p_player;
  delete from game.player_vehicles where player_id = p_player;
  insert into game.admin_audit_log (admin_id, target_id, action) values (pid, p_player, 'reset');
  perform game.add_event(p_player, 'system', 'Your soldier was reset by Command Staff.');
  return jsonb_build_object('message', format('%s has been reset.', t.username));
end $$;

revoke all on all functions in schema game from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
