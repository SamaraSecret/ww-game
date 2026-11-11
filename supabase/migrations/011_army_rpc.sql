-- Army Command RPCs, army-aware combat, public force class.

create or replace function game.max_troops(lvl int) returns int
language sql immutable set search_path = '' as $$ select 100 + (lvl - 1) * 60 $$;

create or replace function game.vehicle_cap(lvl int, min_lvl int) returns int
language sql immutable set search_path = '' as $$
  select case when lvl < min_lvl then 0 else least(10, 1 + (lvl - min_lvl) / 4) end $$;

-- Cost of recruiting n troops when you already have t (cost per troop rises with force size).
create or replace function game.recruit_cost(t int, n int) returns bigint
language sql immutable set search_path = '' as $$
  select (n * 20 + ceil(0.2 * (n::numeric * t + n::numeric * (n - 1) / 2)))::bigint $$;

create or replace function game.force_class(power numeric) returns text
language sql immutable set search_path = '' as $$
  select case when power <= 0 then 'No force' when power < 100 then 'Squad' when power < 500 then 'Platoon'
              when power < 2000 then 'Company' when power < 8000 then 'Battalion' when power < 25000 then 'Regiment'
              when power < 80000 then 'Brigade' else 'Division' end $$;

-- Army strength. Each troop carries at most one weapon (best weapons are issued first).
create or replace function game.army_power(pid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  with p as (select troops from game.players where id = pid),
  w as (select tw.attack, tw.defense, pw.qty,
               sum(pw.qty) over (order by tw.attack desc, tw.id) as cum
          from game.player_troop_weapons pw join game.troop_weapons tw on tw.id = pw.weapon_id
         where pw.player_id = pid),
  wa as (select coalesce(sum(least(w.qty, greatest(0, p.troops - (w.cum - w.qty))) * w.attack), 0) as atk,
                coalesce(sum(least(w.qty, greatest(0, p.troops - (w.cum - w.qty))) * w.defense), 0) as def,
                coalesce(sum(least(w.qty, greatest(0, p.troops - (w.cum - w.qty)))), 0) as armed
           from p left join w on true),
  v as (select coalesce(sum(vh.attack * pv.condition / 100.0), 0) as atk,
               coalesce(sum(vh.defense * pv.condition / 100.0), 0) as def, count(pv.id) as n
          from game.player_vehicles pv join game.vehicles vh on vh.id = pv.vehicle_id where pv.player_id = pid)
  select jsonb_build_object('troops', p.troops, 'armed', wa.armed, 'vehicles', v.n,
           'attack', round(p.troops + wa.atk + v.atk), 'defense', round(p.troops + wa.def + v.def),
           'power', round(2 * p.troops + wa.atk + wa.def + v.atk + v.def))
    from p, wa, v $$;

revoke all on all functions in schema game from public, anon, authenticated;

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
        'price', w.price, 'min_level', w.min_level, 'description', w.description, 'owned', coalesce(o.qty, 0)) order by w.attack)
       from game.troop_weapons w left join game.player_troop_weapons o on o.weapon_id = w.id and o.player_id = pid), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name, 'attack', v.attack, 'defense', v.defense,
        'price', v.price, 'min_level', v.min_level, 'description', v.description, 'cap', game.vehicle_cap(p.level, v.min_level),
        'units', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'condition', u.condition,
              'repair_cost', ceil(v.price * 0.25 * (100 - u.condition) / 100.0)::bigint,
              'sell_value', floor(v.price * 0.4 * u.condition / 100.0)::bigint) order by u.id)
            from game.player_vehicles u where u.player_id = pid and u.vehicle_id = v.id), '[]'::jsonb)) order by v.price)
       from game.vehicles v), '[]'::jsonb));
end $$;

create or replace function public.recruit_troops(p_token text, p_count int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; cost bigint; en int; mx int;
begin
  if p_count is null or p_count < 1 or p_count > 1000 then raise exception 'Recruit between 1 and 1,000 troops at a time.'; end if;
  p := game.tick(pid);
  perform game.require_free(p);
  mx := game.max_troops(p.level);
  if p.troops + p_count > mx then raise exception 'Your force is capped at % troops at level % (you have %).', mx, p.level, p.troops; end if;
  cost := game.recruit_cost(p.troops, p_count);
  en := ceil(p_count / 20.0);
  if p.cash < cost then raise exception 'Recruiting % troops costs $% (you have $%).', p_count, cost, p.cash; end if;
  if p.energy < en then raise exception 'Recruiting % troops costs % energy (you have %).', p_count, en, p.energy; end if;
  update game.players set troops = troops + p_count, cash = cash - cost, energy = energy - en,
    energy_at = case when energy >= 100 then now() else energy_at end where id = pid;
  return jsonb_build_object('message', format('Recruited %s troops for $%s and %s energy.', p_count, cost, en), 'me', game.me_json(pid));
end $$;

create or replace function public.dismiss_troops(p_token text, p_count int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  p := game.tick(pid);
  if p_count is null or p_count < 1 or p_count > p.troops then raise exception 'You can dismiss between 1 and % troops.', p.troops; end if;
  update game.players set troops = troops - p_count where id = pid;
  return jsonb_build_object('message', format('Dismissed %s troops.', p_count), 'me', game.me_json(pid));
end $$;

create or replace function public.buy_troop_weapon(p_token text, p_weapon int, p_qty int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; w game.troop_weapons; owned int; cost bigint; mx int;
begin
  select * into w from game.troop_weapons where id = p_weapon;
  if not found then raise exception 'Unknown weapon.'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 1000 then raise exception 'Buy between 1 and 1,000 at a time.'; end if;
  p := game.tick(pid);
  if p.level < w.min_level then raise exception 'You need level % for %.', w.min_level, w.name; end if;
  owned := coalesce((select qty from game.player_troop_weapons where player_id = pid and weapon_id = p_weapon), 0);
  mx := game.max_troops(p.level);
  if owned + p_qty > mx then raise exception 'You can stock at most % % at level % (you have %).', mx, w.name, p.level, owned; end if;
  cost := w.price * p_qty;
  if p.cash < cost then raise exception '% % cost $% (you have $%).', p_qty, w.name, cost, p.cash; end if;
  update game.players set cash = cash - cost where id = pid;
  insert into game.player_troop_weapons (player_id, weapon_id, qty) values (pid, p_weapon, p_qty)
    on conflict (player_id, weapon_id) do update set qty = game.player_troop_weapons.qty + excluded.qty;
  return jsonb_build_object('message', format('Bought %s %s for $%s.', p_qty, w.name, cost), 'me', game.me_json(pid));
end $$;

create or replace function public.sell_troop_weapon(p_token text, p_weapon int, p_qty int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; w game.troop_weapons; owned int; val bigint;
begin
  select * into w from game.troop_weapons where id = p_weapon;
  if not found then raise exception 'Unknown weapon.'; end if;
  p := game.tick(pid);
  owned := coalesce((select qty from game.player_troop_weapons where player_id = pid and weapon_id = p_weapon), 0);
  if p_qty is null or p_qty < 1 or p_qty > owned then raise exception 'You can sell between 1 and % %.', owned, w.name; end if;
  val := (w.price * p_qty) / 2;
  if p_qty = owned then delete from game.player_troop_weapons where player_id = pid and weapon_id = p_weapon;
  else update game.player_troop_weapons set qty = qty - p_qty where player_id = pid and weapon_id = p_weapon; end if;
  update game.players set cash = cash + val where id = pid;
  return jsonb_build_object('message', format('Sold %s %s for $%s.', p_qty, w.name, val), 'me', game.me_json(pid));
end $$;

create or replace function public.buy_vehicle(p_token text, p_vehicle int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; v game.vehicles; n int; cap int;
begin
  select * into v from game.vehicles where id = p_vehicle;
  if not found then raise exception 'Unknown vehicle.'; end if;
  p := game.tick(pid);
  if p.level < v.min_level then raise exception 'You need level % for a %.', v.min_level, v.name; end if;
  cap := game.vehicle_cap(p.level, v.min_level);
  select count(*) into n from game.player_vehicles where player_id = pid and vehicle_id = p_vehicle;
  if n >= cap then raise exception 'Your motor pool can hold % % at level %.', cap, v.name, p.level; end if;
  if p.cash < v.price then raise exception 'A % costs $% (you have $%).', v.name, v.price, p.cash; end if;
  update game.players set cash = cash - v.price where id = pid;
  insert into game.player_vehicles (player_id, vehicle_id) values (pid, p_vehicle);
  return jsonb_build_object('message', format('A new %s joins your motor pool ($%s).', v.name, v.price), 'me', game.me_json(pid));
end $$;

create or replace function public.sell_vehicle(p_token text, p_unit bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; u game.player_vehicles; v game.vehicles; val bigint;
begin
  p := game.tick(pid);
  select * into u from game.player_vehicles where id = p_unit and player_id = pid for update;
  if not found then raise exception 'You do not own that vehicle.'; end if;
  select * into v from game.vehicles where id = u.vehicle_id;
  val := floor(v.price * 0.4 * u.condition / 100.0);
  delete from game.player_vehicles where id = u.id;
  update game.players set cash = cash + val where id = pid;
  return jsonb_build_object('message', format('Sold %s (%s%% condition) for $%s.', v.name, u.condition, val), 'me', game.me_json(pid));
end $$;

create or replace function public.repair_vehicle(p_token text, p_unit bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; u game.player_vehicles; v game.vehicles; cost bigint;
begin
  p := game.tick(pid);
  select * into u from game.player_vehicles where id = p_unit and player_id = pid for update;
  if not found then raise exception 'You do not own that vehicle.'; end if;
  if u.condition >= 100 then raise exception 'That vehicle is already in perfect condition.'; end if;
  select * into v from game.vehicles where id = u.vehicle_id;
  cost := ceil(v.price * 0.25 * (100 - u.condition) / 100.0);
  if p.cash < cost then raise exception 'Repairs cost $% (you have $%).', cost, p.cash; end if;
  update game.players set cash = cash - cost where id = pid;
  update game.player_vehicles set condition = 100 where id = u.id;
  return jsonb_build_object('message', format('%s repaired for $%s.', v.name, cost), 'me', game.me_json(pid));
end $$;

create or replace function public.repair_all_vehicles(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; cost bigint;
begin
  p := game.tick(pid);
  perform 1 from game.player_vehicles where player_id = pid for update;
  select coalesce(sum(ceil(v.price * 0.25 * (100 - u.condition) / 100.0)), 0)::bigint into cost
    from game.player_vehicles u join game.vehicles v on v.id = u.vehicle_id where u.player_id = pid and u.condition < 100;
  if cost = 0 then raise exception 'Nothing needs repair.'; end if;
  if p.cash < cost then raise exception 'Repairing everything costs $% (you have $%).', cost, p.cash; end if;
  update game.players set cash = cash - cost where id = pid;
  update game.player_vehicles set condition = 100 where player_id = pid and condition < 100;
  return jsonb_build_object('message', format('All vehicles repaired for $%s.', cost), 'me', game.me_json(pid));
end $$;

-- Public profile: adds a coarse "force" label only (never exact numbers).
create or replace function game.public_player(p game.players) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'level', p.level, 'rank', game.rank_title(p.level),
    'npc', p.is_npc, 'staff', p.is_admin,
    'status', case when p.banned then 'Discharged' when p.is_npc then 'Okay' else game.status_of(p.hospital_until, p.jail_until) end,
    'faction', (select jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag) from game.factions f where f.id = p.faction_id),
    'force', game.force_class((game.army_power(p.id)->>'power')::numeric),
    'wins', p.wins, 'losses', p.losses, 'joined', p.created_at::date,
    'online', (not p.is_npc and p.last_action > now() - interval '15 minutes')
  ) $$;
revoke all on function game.public_player(game.players) from public, anon, authenticated;

create or replace function public.leaderboard(p_token text, p_kind text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  if p_kind not in ('level','wins','stats','wealth','army') then raise exception 'Unknown leaderboard.'; end if;
  -- For 'stats', 'wealth' and 'army' only the ORDER is public; exact numbers stay private.
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'username', username, 'level', level,
          'rank', game.rank_title(level), 'value', case p_kind when 'level' then level when 'wins' then wins else null end)
          order by pos) from (
      select id, username, level, wins, row_number() over (order by
          case p_kind when 'level' then level::numeric when 'wins' then wins::numeric
                      when 'stats' then (str + def + spd + dex)
                      when 'army' then (game.army_power(id)->>'power')::numeric
                      else (cash + bank)::numeric end desc, xp desc, id) as pos
        from game.players where not is_npc and not is_admin and not banned) r where pos <= 20), '[]'::jsonb);
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
    wins = 0, losses = 0, missions_done = 0, troops = 0 where id = p_player;
  delete from game.inventory where player_id = p_player;
  delete from game.player_troop_weapons where player_id = p_player;
  delete from game.player_vehicles where player_id = p_player;
  insert into game.admin_log (admin_id, target_id, action) values (pid, p_player, 'reset');
  perform game.add_event(p_player, 'system', 'Your soldier was reset by Command Staff.');
  return jsonb_build_object('message', format('%s has been reset.', t.username));
end $$;

-- Private self view now includes the player's own force.
create or replace function game.me_json(pid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'is_admin', p.is_admin,
    'level', p.level, 'rank', game.rank_title(p.level),
    'xp', p.xp, 'xp_prev', case when p.level = 1 then 0 else game.xp_for(p.level - 1) end, 'xp_next', game.xp_for(p.level),
    'cash', p.cash, 'bank', p.bank,
    'hp', p.hp, 'max_hp', game.max_hp(p.level),
    'energy', p.energy, 'max_energy', 100, 'nerve', p.nerve, 'max_nerve', 10,
    'energy_next', case when p.energy >= 100 then null else greatest(0, 300 - extract(epoch from (now() - p.energy_at)))::int end,
    'nerve_next', case when p.nerve >= 10 then null else greatest(0, 300 - extract(epoch from (now() - p.nerve_at)))::int end,
    'str', p.str, 'def', p.def, 'spd', p.spd, 'dex', p.dex, 'total', p.str + p.def + p.spd + p.dex,
    'weapon', (select jsonb_build_object('id', i.id, 'name', i.name, 'power', i.power) from game.items i where i.id = p.weapon_id),
    'armor', (select jsonb_build_object('id', i.id, 'name', i.name, 'power', i.power) from game.items i where i.id = p.armor_id),
    'status', game.status_of(p.hospital_until, p.jail_until),
    'hospital_until', case when p.hospital_until > now() then p.hospital_until end,
    'jail_until', case when p.jail_until > now() then p.jail_until end,
    'faction', (select jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'leader', f.leader_id = p.id) from game.factions f where f.id = p.faction_id),
    'troops', p.troops, 'max_troops', game.max_troops(p.level),
    'force_class', game.force_class((game.army_power(p.id)->>'power')::numeric),
    'wins', p.wins, 'losses', p.losses, 'missions_done', p.missions_done,
    'server_time', now()
  ) from game.players p where p.id = pid $$;


-- Army-aware combat (replaces the version in 004).
create or replace function public.attack(p_token text, p_target bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  pid bigint := game.auth(p_token);
  a game.players; d game.players;
  a_w text; a_wp int := 0; a_ap int := 0;
  d_w text; d_wp int := 0; d_ap int := 0;
  a_hp int; d_hp int; a_max int; d_max int;
  v_log text[] := '{}';
  r int; s int; a_first boolean; atk_is_a boolean;
  chance numeric; dmg int; crit boolean;
  outcome text; v_cash bigint := 0; v_xp int := 0; mins int; msg text;
  a_army jsonb; d_army jsonb; fa numeric; fd numeric;
  a_lp numeric; d_lp numeric; a_w1 int; a_w2 int; d_w1 int; d_w2 int; a_lost int := 0; d_lost int := 0; d_note text := '';
begin
  if p_target is null or p_target = pid then raise exception 'You cannot attack yourself.'; end if;
  if not exists (select 1 from game.players where id = p_target) then raise exception 'Target not found.'; end if;
  -- lock both rows in a fixed order to avoid deadlocks / double-spends
  if pid < p_target then a := game.tick(pid); d := game.tick(p_target);
  else d := game.tick(p_target); a := game.tick(pid); end if;

  perform game.require_free(a);
  if a.energy < 25 then raise exception 'Attacking costs 25 energy (you have %).', a.energy; end if;
  a_max := game.max_hp(a.level); d_max := game.max_hp(d.level);
  if a.hp < ceil(a_max * 0.2) then raise exception 'You are too wounded to fight. Rest or visit the hospital.'; end if;
  if d.banned or d.is_admin then raise exception 'That target is not available.'; end if;
  if not d.is_npc then
    if d.level < 3 then raise exception 'New recruits below level 3 are protected.'; end if;
    if d.hospital_until is not null then raise exception '% is already in the hospital.', d.username; end if;
    if d.jail_until is not null then raise exception '% is held in the stockade.', d.username; end if;
    if exists (select 1 from game.attacks where attacker_id = pid and defender_id = p_target
                and created_at > now() - interval '10 minutes') then
      raise exception 'You attacked % recently. Wait for the 10 minute cooldown.', d.username;
    end if;
  end if;

  select name, power into a_w, a_wp from game.items where id = a.weapon_id;
  select power into a_ap from game.items where id = a.armor_id;
  select name, power into d_w, d_wp from game.items where id = d.weapon_id;
  select power into d_ap from game.items where id = d.armor_id;
  a_wp := coalesce(a_wp, 0); a_ap := coalesce(a_ap, 0); d_wp := coalesce(d_wp, 0); d_ap := coalesce(d_ap, 0);
  a_w := coalesce(a_w, 'bare fists'); d_w := coalesce(d_w, 'bare fists');

  -- Army Command: army power scales damage between x0.6 and x1.5
  a_army := game.army_power(a.id); d_army := game.army_power(d.id);
  fa := least(1.5, greatest(0.6, 1 + 0.5 * ((a_army->>'attack')::numeric - (d_army->>'defense')::numeric)
                                      / ((a_army->>'attack')::numeric + (d_army->>'defense')::numeric + 200)));
  fd := least(1.5, greatest(0.6, 1 + 0.5 * ((d_army->>'attack')::numeric - (a_army->>'defense')::numeric)
                                      / ((d_army->>'attack')::numeric + (a_army->>'defense')::numeric + 200)));

  a_hp := a.hp; d_hp := case when d.is_npc then d_max else d.hp end;
  a_first := a.spd * (0.8 + random() * 0.4) >= d.spd * (0.8 + random() * 0.4);
  v_log := v_log || format('%s engages %s. %s moves first.', a.username, d.username,
                       case when a_first then a.username else d.username end);
  v_log := v_log || format('Forces: %s leads a %s, %s leads a %s. Army support: %s damage x%s, %s damage x%s.',
                           a.username, game.force_class((a_army->>'power')::numeric), d.username, game.force_class((d_army->>'power')::numeric),
                           a.username, round(fa, 2), d.username, round(fd, 2));

  <<rounds>>
  for r in 1..12 loop
    for s in 0..1 loop
      atk_is_a := (s = 0) = a_first;
      if atk_is_a then
        chance := least(0.95, greatest(0.25, a.spd / (a.spd + d.dex) * 1.1 + 0.05));
        if random() < chance then
          crit := random() < 0.15;
          dmg := greatest(1, round((10 + a.str * 0.8 + a_wp) * (0.8 + random() * 0.4)
                         * (100.0 / (100.0 + d.def * 0.5 + d_ap * 2)) * case when crit then 1.5 else 1 end * fa));
          d_hp := greatest(0, d_hp - dmg);
          v_log := v_log || format('R%s: %s hits %s with %s for %s%s. (%s HP left)', r, a.username, d.username, a_w, dmg,
                               case when crit then ' (critical!)' else '' end, d_hp);
        else
          v_log := v_log || format('R%s: %s attacks with %s but %s evades.', r, a.username, a_w, d.username);
        end if;
      else
        chance := least(0.95, greatest(0.25, d.spd / (d.spd + a.dex) * 1.1 + 0.05));
        if random() < chance then
          crit := random() < 0.15;
          dmg := greatest(1, round((10 + d.str * 0.8 + d_wp) * (0.8 + random() * 0.4)
                         * (100.0 / (100.0 + a.def * 0.5 + a_ap * 2)) * case when crit then 1.5 else 1 end * fd));
          a_hp := greatest(0, a_hp - dmg);
          v_log := v_log || format('R%s: %s hits %s with %s for %s%s. (%s HP left)', r, d.username, a.username, d_w, dmg,
                               case when crit then ' (critical!)' else '' end, a_hp);
        else
          v_log := v_log || format('R%s: %s attacks with %s but %s evades.', r, d.username, d_w, a.username);
        end if;
      end if;
      exit rounds when a_hp <= 0 or d_hp <= 0;
    end loop;
  end loop;

  if d_hp <= 0 then
    outcome := 'win';
    v_xp := 10 + d.level * 8;
    if d.is_npc then
      v_cash := d.level * 40 + floor(random() * (d.level * 20 + 1))::bigint;
    else
      v_cash := floor(d.cash * (0.03 + random() * 0.05))::bigint;
      mins := 5 + floor(random() * 6)::int + d.level / 4;
      update game.players set hp = 0, cash = cash - v_cash, losses = losses + 1,
        hospital_until = now() + make_interval(mins => mins) where id = d.id;
      perform game.add_event(d.id, 'battle', format('%s attacked you and won. You lost $%s and were hospitalized for %s minutes.', a.username, v_cash, mins));
    end if;
    update game.players set hp = a_hp, energy = energy - 25, cash = cash + v_cash, wins = wins + 1,
      energy_at = case when energy >= 100 then now() else energy_at end,
      hp_at = case when hp >= a_max then now() else hp_at end where id = pid;
    perform game.add_xp(pid, v_xp);
    msg := format('Victory over %s! You took $%s and earned %s XP.', d.username, v_cash, v_xp);
    v_log := v_log || format('%s is defeated.', d.username);
  elsif a_hp <= 0 then
    outcome := 'loss';
    mins := 5 + floor(random() * 6)::int + a.level / 4;
    update game.players set hp = 0, energy = energy - 25, losses = losses + 1,
      energy_at = case when energy >= 100 then now() else energy_at end,
      hospital_until = now() + make_interval(mins => mins) where id = pid;
    if not d.is_npc then
      update game.players set hp = d_hp, wins = wins + 1,
        hp_at = case when hp >= d_max then now() else hp_at end where id = d.id;
      perform game.add_xp(d.id, 5 + a.level * 2);
      perform game.add_event(d.id, 'battle', format('%s attacked you and lost. You held your ground!', a.username));
    end if;
    msg := format('Defeat. %s beat you and you were hospitalized for %s minutes.', d.username, mins);
    v_log := v_log || format('%s is defeated.', a.username);
  else
    outcome := 'stalemate';
    update game.players set hp = a_hp, energy = energy - 25,
      energy_at = case when energy >= 100 then now() else energy_at end,
      hp_at = case when hp >= a_max then now() else hp_at end where id = pid;
    if not d.is_npc then
      update game.players set hp = d_hp, hp_at = case when hp >= d_max then now() else hp_at end where id = d.id;
      perform game.add_event(d.id, 'battle', format('%s attacked you but withdrew after a stalemate.', a.username));
    end if;
    msg := format('Stalemate. Neither side broke, and you withdrew from %s.', d.username);
    v_log := v_log || 'Both sides withdraw.';
  end if;

  -- Casualties and vehicle wear (NPC forces always regroup)
  if outcome = 'win' then a_lp := 0.01 + random() * 0.03; d_lp := 0.06 + random() * 0.06; a_w1 := 1; a_w2 := 5; d_w1 := 4; d_w2 := 10;
  elsif outcome = 'loss' then a_lp := 0.06 + random() * 0.06; d_lp := 0.01 + random() * 0.03; a_w1 := 4; a_w2 := 10; d_w1 := 1; d_w2 := 5;
  else a_lp := 0.02 + random() * 0.03; d_lp := 0.02 + random() * 0.03; a_w1 := 2; a_w2 := 6; d_w1 := 2; d_w2 := 6; end if;
  a_lost := floor(a.troops * a_lp);
  update game.players set troops = greatest(0, troops - a_lost) where id = a.id;
  update game.player_vehicles set condition = greatest(0, condition - (a_w1 + floor(random() * (a_w2 - a_w1 + 1)))::int) where player_id = a.id;
  if a.troops > 0 or (a_army->>'vehicles')::int > 0 then
    v_log := v_log || format('Casualties: %s lost %s troops%s.', a.username, a_lost,
                             case when (a_army->>'vehicles')::int > 0 then format(' and vehicles took %s-%s%% wear', a_w1, a_w2) else '' end);
  end if;
  if not d.is_npc then
    d_lost := floor(d.troops * d_lp);
    update game.players set troops = greatest(0, troops - d_lost) where id = d.id;
    update game.player_vehicles set condition = greatest(0, condition - (d_w1 + floor(random() * (d_w2 - d_w1 + 1)))::int) where player_id = d.id;
    if d_lost > 0 then d_note := format(' You lost %s troops.', d_lost); end if;
    if d.troops > 0 then
      v_log := v_log || format('%s suffered %s casualties.', d.username, case when d_lp >= 0.06 then 'heavy' else 'light' end);
    end if;
    update game.events set message = message || d_note
     where id = (select max(id) from game.events where player_id = d.id and kind = 'battle');
  end if;
  if a_lost > 0 then msg := msg || format(' You lost %s troops.', a_lost); end if;

  insert into game.attacks (attacker_id, defender_id, result) values (pid, d.id, outcome);
  perform game.add_event(pid, 'battle', msg);
  return jsonb_build_object('result', outcome, 'message', msg, 'log', to_jsonb(v_log),
                            'cash', v_cash, 'xp', v_xp, 'me', game.me_json(pid));
end $$;

revoke all on all functions in schema game from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
