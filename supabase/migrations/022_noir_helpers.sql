-- Noir Syndicate helpers: ranks, money, economy tick, crew power, me_json.

create or replace function game.rank_title(lvl int) returns text
language sql immutable set search_path = '' as $$
  select case
    when lvl >= 500 then 'Underworld Legend ' || ((lvl - 500) / 100 + 1)::text
    when lvl >= 250 then 'Eternal ' || ((lvl - 200) / 50 + 1)::text
    when lvl >= 200 then 'Eternal'
    when lvl >= 150 then 'Grayhaven Legend'
    when lvl >= 100 then 'Underworld Legend'
    when lvl >= 75  then 'Underworld Lord'
    when lvl >= 50  then 'Night Sovereign'
    when lvl >= 40  then 'Shadow Don'
    when lvl >= 30  then 'Kingpin'
    when lvl >= 25  then 'Don'
    when lvl >= 20  then 'Underboss'
    when lvl >= 15  then 'Consigliere'
    when lvl >= 11  then 'Capo'
    when lvl >= 8   then 'Made Hand'
    when lvl >= 5   then 'Operator'
    when lvl >= 3   then 'Tough'
    else 'Runner' end $$;

create or replace function game.status_of(h timestamptz, j timestamptz) returns text
language sql stable set search_path = '' as $$
  select case when h is not null and h > now() then 'Hospital'
              when j is not null and j > now() then 'Jail'
              else 'Okay' end $$;

create or replace function game.require_free(p game.players) returns void
language plpgsql stable set search_path = '' as $$
begin
  if p.hospital_until is not null and p.hospital_until > now() then
    raise exception 'You are in the hospital for another % minute(s).', ceil(extract(epoch from (p.hospital_until - now())) / 60);
  end if;
  if p.jail_until is not null and p.jail_until > now() then
    raise exception 'You are in jail for another % minute(s).', ceil(extract(epoch from (p.jail_until - now())) / 60);
  end if;
end $$;

create or replace function game.require_admin(pid bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from game.players where id = pid and is_admin and not banned) then
    raise exception 'Access denied.';
  end if;
end $$;

create or replace function game.reserved_name(u text) returns boolean
language sql immutable set search_path = '' as $$
  select lower(u) ~ '(admin|moderat|staff|system|official|support|owner|operator|webmaster|theboss|the_boss)'
      or lower(u) ~ '^(mod|mods|gm|gms|cmd|root|dev|sysop|sys|server|npc|bot|boss|don|kingpin)([_0-9]|$)'
      or lower(u) ~ '(^|_)(mod|gm|cmd|boss)$'
      or lower(u) in ('noir','syndicate','underworld','grayhaven','cartel')
$$;

create or replace function game.crew_class(power numeric) returns text
language sql immutable set search_path = '' as $$
  select case
    when power >= 4000 then 'Empire'
    when power >= 1500 then 'Syndicate'
    when power >= 500  then 'Family'
    when power >= 150  then 'Outfit'
    when power >= 1    then 'Street Crew'
    else 'None' end $$;

-- Keep the old name as a wrapper so leftover references still resolve during this migration.
create or replace function game.force_class(power numeric) returns text
language sql immutable set search_path = '' as $$
  select game.crew_class(power) $$;

-- Crew power: troops + issued crew weapons only (cars are a separate economy).
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
           from p left join w on true)
  select jsonb_build_object('troops', p.troops, 'armed', wa.armed, 'vehicles', 0,
           'attack', round(p.troops + wa.atk), 'defense', round(p.troops + wa.def),
           'power', round(2 * p.troops + wa.atk + wa.def),
           'class', game.crew_class(round(2 * p.troops + wa.atk + wa.def)))
    from p, wa
$$;

create or replace function game.crew_power(pid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select game.army_power(pid) $$;

-- Money helpers. Caller must already hold a FOR UPDATE lock on the player (via game.tick).
create or replace function game.add_dirty(pid bigint, amt bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(amt, 0) <= 0 then return; end if;
  update game.players set cash = cash + amt where id = pid;
end $$;

create or replace function game.add_clean(pid bigint, amt bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(amt, 0) <= 0 then return; end if;
  update game.players set clean_cash = clean_cash + amt where id = pid;
end $$;

create or replace function game.take_dirty(pid bigint, amt bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare have bigint;
begin
  if coalesce(amt, 0) <= 0 then raise exception 'Invalid amount.'; end if;
  select cash into have from game.players where id = pid;
  if have is null or have < amt then raise exception 'Not enough dirty cash.'; end if;
  update game.players set cash = cash - amt where id = pid;
end $$;

create or replace function game.take_clean(pid bigint, amt bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare have bigint;
begin
  if coalesce(amt, 0) <= 0 then raise exception 'Invalid amount.'; end if;
  select clean_cash into have from game.players where id = pid;
  if have is null or have < amt then raise exception 'Not enough clean cash.'; end if;
  update game.players set clean_cash = clean_cash - amt where id = pid;
end $$;

-- Spend dirty first, then clean. Used for hospital, bail and similar.
create or replace function game.take_any(pid bigint, amt bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare d bigint; c bigint; need bigint;
begin
  if coalesce(amt, 0) <= 0 then raise exception 'Invalid amount.'; end if;
  select cash, clean_cash into d, c from game.players where id = pid;
  if coalesce(d,0) + coalesce(c,0) < amt then raise exception 'Not enough cash.'; end if;
  need := amt;
  if d >= need then
    update game.players set cash = cash - need where id = pid;
  else
    update game.players set cash = 0, clean_cash = clean_cash - (need - d) where id = pid;
  end if;
end $$;

-- Specialization passives. Multipliers default to 1.
create or replace function game.path_mods(spec text)
returns jsonb
language sql immutable set search_path = '' as $$
  select case spec
    when 'enforcer' then jsonb_build_object('dmg', 1.15, 'crime_cash', 1.00, 'crime_chance', 0.00, 'jail', 1.00, 'bail', 1.00, 'launder_fee', 1.00, 'chop', 1.00, 'hit', 1.00)
    when 'hustler'  then jsonb_build_object('dmg', 1.00, 'crime_cash', 1.20, 'crime_chance', 0.03, 'jail', 1.00, 'bail', 1.00, 'launder_fee', 0.80, 'chop', 1.20, 'hit', 1.00)
    when 'fixer'    then jsonb_build_object('dmg', 1.00, 'crime_cash', 1.00, 'crime_chance', 0.05, 'jail', 0.70, 'bail', 0.70, 'launder_fee', 1.00, 'chop', 1.00, 'hit', 1.00)
    when 'ghost'    then jsonb_build_object('dmg', 1.10, 'crime_cash', 1.00, 'crime_chance', 0.04, 'jail', 0.90, 'bail', 1.00, 'launder_fee', 1.00, 'chop', 1.00, 'hit', 1.25)
    else                jsonb_build_object('dmg', 1.00, 'crime_cash', 1.00, 'crime_chance', 0.00, 'jail', 1.00, 'bail', 1.00, 'launder_fee', 1.00, 'chop', 1.00, 'hit', 1.00)
  end $$;

-- Apply pending business laundering. Must be called while the player row is locked.
create or replace function game.tick_economy(pid bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare
  p game.players;
  rec record;
  hours numeric;
  cap_hours numeric := 48;
  room bigint;
  take bigint;
  fee numeric;
  cleaned bigint;
  total_dirty bigint := 0;
  total_clean bigint := 0;
begin
  select * into p from game.players where id = pid;
  if not found then return; end if;
  for rec in
    select pb.business_id, pb.last_run_at, bt.launder_per_hour, bt.fee_bps
      from game.player_businesses pb
      join game.business_types bt on bt.id = pb.business_id
     where pb.player_id = pid
     for update of pb
  loop
    hours := least(cap_hours, extract(epoch from (now() - rec.last_run_at)) / 3600.0);
    if hours < 0.05 then continue; end if; -- ~3 minutes
    select cash into room from game.players where id = pid;
    take := least(room, floor(rec.launder_per_hour * hours))::bigint;
    if take > 0 then
      fee := (rec.fee_bps / 10000.0) * coalesce((game.path_mods(p.specialization)->>'launder_fee')::numeric, 1);
      cleaned := floor(take * (1 - fee))::bigint;
      perform game.take_dirty(pid, take);
      perform game.add_clean(pid, cleaned);
      total_dirty := total_dirty + take;
      total_clean := total_clean + cleaned;
    end if;
    update game.player_businesses set last_run_at = now() where player_id = pid and business_id = rec.business_id;
  end loop;
  update game.players set last_economy_at = now() where id = pid;
  if total_clean > 0 then
    perform game.add_event(pid, 'launder',
      format('Your fronts cleaned $%s of dirty cash into $%s clean (fees kept the rest).',
             to_char(total_dirty, 'FM999,999,999,999'), to_char(total_clean, 'FM999,999,999,999')));
  end if;
end $$;

create or replace function game.add_xp(pid bigint, amt bigint) returns integer
language plpgsql security definer set search_path = '' as $$
declare lvl int; x bigint; gained int := 0; ft int := 0; sp int := 0; target int; cap int := game.max_level();
begin
  update game.players
     set xp = least(game.xp_for(cap), xp + greatest(coalesce(amt, 0), 0))
   where id = pid
   returning level, xp into lvl, x;
  if not found then return 0; end if;
  target := least(cap, greatest(lvl, (floor(sqrt(x::numeric / 50.0)) + 1)::int));
  gained := target - lvl;
  if gained > 0 then
    lvl := target;
    update game.players set level = lvl,
      hp = case when hospital_until is null then game.max_hp(lvl) else hp end
     where id = pid;
    ft := game.grant_level_troops(pid, gained);
    sp := game.grant_level_stats(pid, lvl);
    perform game.add_event(pid, 'promotion', format('You reached level %s (%s).%s%s', lvl, game.rank_title(lvl),
      case when sp > 0 then format(' You gained %s stat points.', sp) else '' end,
      case when ft > 0 then format(' %s new crew showed up on their own.', ft) else '' end));
  end if;
  return gained;
end $$;

create or replace function game.me_json(pid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'username', p.username, 'is_admin', p.is_admin,
    'level', p.level, 'rank', game.rank_title(p.level), 'max_level', game.max_level(),
    'xp', p.xp, 'xp_prev', case when p.level = 1 then 0 else game.xp_for(p.level - 1) end,
    'xp_next', game.xp_for(p.level),
    'cash', p.cash, 'dirty', p.cash, 'clean', p.clean_cash, 'bank', p.bank,
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
    'jail_until', case when p.jail_until > now() then p.jail_until end
  ) || jsonb_build_object(
    'faction', (select jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'leader', f.leader_id = p.id) from game.factions f where f.id = p.faction_id),
    'troops', p.troops, 'max_troops', game.max_troops(p.level), 'troops_cap', 1000,
    'troops_free_granted', p.troops_free_granted, 'free_troops_cap', 300,
    'immortal', p.immortal, 'god_strike', p.god_strike,
    'force_class', game.crew_class((game.army_power(p.id)->>'power')::numeric),
    'crew_class', game.crew_class((game.army_power(p.id)->>'power')::numeric),
    'wins', p.wins, 'losses', p.losses,
    'missions_done', p.crimes_done, 'crimes_done', p.crimes_done,
    'specialization', p.specialization,
    'path_buff', case when p.path_buff_until > now() then p.path_buff end,
    'path_buff_until', case when p.path_buff_until > now() then p.path_buff_until end,
    'swiss', (select coalesce(sum(amount),0) from game.swiss_cds where player_id = p.id and not collected),
    'server_time', now()
  )
  from game.players p where p.id = pid $$;

revoke all on function game.rank_title(int) from public, anon, authenticated;
revoke all on function game.status_of(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function game.require_free(game.players) from public, anon, authenticated;
revoke all on function game.require_admin(bigint) from public, anon, authenticated;
revoke all on function game.reserved_name(text) from public, anon, authenticated;
revoke all on function game.crew_class(numeric) from public, anon, authenticated;
revoke all on function game.force_class(numeric) from public, anon, authenticated;
revoke all on function game.army_power(bigint) from public, anon, authenticated;
revoke all on function game.crew_power(bigint) from public, anon, authenticated;
revoke all on function game.add_dirty(bigint, bigint) from public, anon, authenticated;
revoke all on function game.add_clean(bigint, bigint) from public, anon, authenticated;
revoke all on function game.take_dirty(bigint, bigint) from public, anon, authenticated;
revoke all on function game.take_clean(bigint, bigint) from public, anon, authenticated;
revoke all on function game.take_any(bigint, bigint) from public, anon, authenticated;
revoke all on function game.path_mods(text) from public, anon, authenticated;
revoke all on function game.tick_economy(bigint) from public, anon, authenticated;
revoke all on function game.add_xp(bigint, bigint) from public, anon, authenticated;
revoke all on function game.me_json(bigint) from public, anon, authenticated;
