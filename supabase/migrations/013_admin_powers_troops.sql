-- Admin Command Powers, audit log, hidden admin, and new army-size rules.

alter table game.players add column if not exists immortal boolean not null default false;
alter table game.players add column if not exists god_strike boolean not null default false;
alter table game.players add column if not exists troops_free_granted int not null default 0;
alter table game.players add constraint players_free_troops_cap check (troops_free_granted between 0 and 300);
update game.players set troops = 1000 where is_npc and troops > 1000;   -- NPCs follow the same 1000 cap
alter table game.players add constraint players_troops_cap check (troops <= 1000);

-- Audit log (admin-only). Replaces admin_log.
alter table game.admin_log rename to admin_audit_log;
alter table game.admin_audit_log add column if not exists details jsonb;
create index if not exists admin_audit_created_idx on game.admin_audit_log (created_at desc);

create or replace function game.audit(a bigint, act text, t bigint default null, d jsonb default null) returns void
language sql security definer set search_path = '' as $$
  insert into game.admin_audit_log (admin_id, target_id, action, details) values (a, t, act, d) $$;

-- Army size: free troops only from levelling (+2 per level, max 300 free in total);
-- everything else is bought in Supplies. Absolute maximum army size: 1000 troops at any level.
create or replace function game.max_troops(lvl int) returns int
language sql immutable set search_path = '' as $$ select 1000 $$;





create or replace function game.grant_level_troops(pid bigint, levels int) returns int
language plpgsql security definer set search_path = '' as $$
declare t int; f int; g int;
begin
  if levels is null or levels <= 0 then return 0; end if;
  select troops, troops_free_granted into t, f from game.players where id = pid and not is_npc for update;
  if not found then return 0; end if;
  g := greatest(0, least(2 * levels, 300 - f, 1000 - t));
  if g > 0 then
    update game.players set troops = troops + g, troops_free_granted = troops_free_granted + g where id = pid;
  end if;
  return g;
end $$;

create or replace function game.add_xp(pid bigint, amt bigint) returns int
language plpgsql security definer set search_path = '' as $$
declare lvl int; x bigint; gained int := 0; ft int;
begin
  update game.players set xp = xp + greatest(amt, 0) where id = pid returning level, xp into lvl, x;
  while x >= game.xp_for(lvl) and lvl < 100 loop
    lvl := lvl + 1; gained := gained + 1;
  end loop;
  if gained > 0 then
    update game.players set level = lvl,
      hp = case when hospital_until is null then game.max_hp(lvl) else hp end
     where id = pid;
    ft := game.grant_level_troops(pid, gained);
    perform game.add_event(pid, 'promotion', format('Promoted to level %s (%s)!%s', lvl, game.rank_title(lvl),
      case when ft > 0 then format(' Command assigned you %s new troops.', ft) else '' end));
  end if;
  return gained;
end $$;

-- One-off: existing players receive the free troops they would have earned for their level.
update game.players set
  troops_free_granted = least(300, 2 * (level - 1), 1000 - troops),
  troops = troops + least(300, 2 * (level - 1), 1000 - troops)
 where not is_npc and troops_free_granted = 0 and level > 1;


create or replace function public.admin_set_ban(p_token text, p_player bigint, p_banned boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); t game.players;
begin
  perform game.require_admin(pid);
  select * into t from game.players where id = p_player for update;
  if not found then raise exception 'Player not found.'; end if;
  if t.id = pid then raise exception 'You cannot ban yourself.'; end if;
  if t.is_admin then raise exception 'You cannot ban another admin.'; end if;
  update game.players set banned = coalesce(p_banned, false) where id = p_player;
  if p_banned then delete from game.sessions where player_id = p_player; end if;
  insert into game.admin_audit_log (admin_id, target_id, action) values (pid, p_player, case when p_banned then 'ban' else 'unban' end);
  return jsonb_build_object('message', format('%s is now %s.', t.username, case when p_banned then 'banned' else 'unbanned' end));
end $$;

create or replace function public.admin_adjust_cash(p_token text, p_player bigint, p_delta bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); t game.players; newc bigint;
begin
  perform game.require_admin(pid);
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000000000 then raise exception 'Amount must be non-zero and at most 1,000,000,000.'; end if;
  t := game.tick(p_player);
  newc := greatest(0, t.cash + p_delta);
  update game.players set cash = newc where id = p_player;
  insert into game.admin_audit_log (admin_id, target_id, action) values (pid, p_player, format('cash %s', p_delta));
  perform game.add_event(p_player, 'system', case when p_delta > 0 then format('Command Staff granted you $%s.', p_delta)
                                                   else format('Command Staff removed $%s from your cash.', -p_delta) end);
  return jsonb_build_object('message', format('%s now has $%s cash.', t.username, newc));
end $$;

create or replace function public.admin_announce(p_token text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); m text := trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g'));
begin
  perform game.require_admin(pid);
  if length(m) > 300 then raise exception 'Announcements are limited to 300 characters.'; end if;
  update game.announcements set active = false where active;
  if length(m) > 0 then insert into game.announcements (message) values (m); end if;
  insert into game.admin_audit_log (admin_id, action) values (pid, case when length(m) > 0 then 'announce' else 'clear announcement' end);
  return jsonb_build_object('message', case when length(m) > 0 then 'Announcement posted.' else 'Announcement cleared.' end);
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
    immortal = false, god_strike = false where id = p_player;
  delete from game.inventory where player_id = p_player;
  delete from game.player_troop_weapons where player_id = p_player;
  delete from game.player_vehicles where player_id = p_player;
  insert into game.admin_audit_log (admin_id, target_id, action) values (pid, p_player, 'reset');
  perform game.add_event(p_player, 'system', 'Your soldier was reset by Command Staff.');
  return jsonb_build_object('message', format('%s has been reset.', t.username));
end $$;

create or replace function public.admin_get_player(p_token text, p_player bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.require_admin(pid);
  if not exists (select 1 from game.players where id = p_player) then raise exception 'Player not found.'; end if;
  perform game.tick(p_player);
  perform game.audit(pid, 'view player', p_player);
  return game.me_json(p_player) || (select jsonb_build_object('banned', banned, 'npc', is_npc,
           'failed_logins', failed_logins, 'locked_until', locked_until, 'created_at', created_at, 'last_action', last_action,
           'sessions', (select count(*) from game.sessions s where s.player_id = p.id and s.expires_at > now()))
         from game.players p where id = p_player);
end $$;

create or replace function public.admin_recent_events(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.require_admin(pid);
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'username', p.username, 'kind', e.kind,
            'message', e.message, 'created_at', e.created_at) order by e.id desc)
     from (select * from game.events order by id desc limit 100) e join game.players p on p.id = e.player_id), '[]'::jsonb);
end $$;

create or replace function public.do_mission(p_token text, p_mission int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  pid bigint := game.auth(p_token);
  p game.players; m game.missions;
  chance numeric; v_cash bigint; dmg int; mins int; msg text; res text; lv int;
begin
  select * into m from game.missions where id = p_mission;
  if not found then raise exception 'Unknown mission.'; end if;
  p := game.tick(pid);
  perform game.require_free(p);
  if p.level < m.min_level then raise exception 'You need level % for this mission.', m.min_level; end if;
  if p.nerve < m.nerve_cost then raise exception 'Not enough nerve (need %, have %).', m.nerve_cost, p.nerve; end if;
  chance := least(0.95, m.base_chance + (p.level - 1) * 0.01 + p.dex / (p.dex + 1000) * 0.25);
  update game.players set nerve = nerve - m.nerve_cost,
    nerve_at = case when nerve >= 10 then now() else nerve_at end where id = pid;
  if random() < chance then
    v_cash := m.cash_min + floor(random() * (m.cash_max - m.cash_min + 1))::bigint;
    update game.players set cash = cash + v_cash, missions_done = missions_done + 1 where id = pid;
    lv := game.add_xp(pid, m.xp);
    res := 'success';
    msg := format('%s Mission "%s" succeeded: +$%s, +%s XP.', m.success_text, m.name, v_cash, m.xp);
  elsif p.immortal then
    res := 'shielded';
    msg := format('%s Command immunity shielded you on "%s".', m.fail_text, m.name);
    perform game.add_xp(pid, 1);
  elsif random() < 0.5 then
    dmg := ceil(game.max_hp(p.level) * (0.15 + random() * 0.25));
    if p.hp - dmg <= 0 then
      mins := 4 + m.tier * 2;
      update game.players set hp = 0, hospital_until = now() + make_interval(mins => mins) where id = pid;
      res := 'hospital';
      msg := format('%s You were badly wounded on "%s" and evacuated to the field hospital for %s minutes.', m.fail_text, m.name, mins);
    else
      update game.players set hp = hp - dmg, hp_at = case when hp >= game.max_hp(level) then now() else hp_at end where id = pid;
      res := 'wounded';
      msg := format('%s You were wounded on "%s" and lost %s HP.', m.fail_text, m.name, dmg);
    end if;
    perform game.add_xp(pid, 1);
  else
    mins := 2 + m.tier * 2;
    update game.players set jail_until = now() + make_interval(mins => mins) where id = pid;
    res := 'stockade';
    msg := format('%s You were captured during "%s" and held in the stockade for %s minutes.', m.fail_text, m.name, mins);
    perform game.add_xp(pid, 1);
  end if;
  perform game.add_event(pid, 'mission', msg);
  return jsonb_build_object('result', res, 'message', msg, 'me', game.me_json(pid));
end $$;

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
  a_disp text; outcome text; v_cash bigint := 0; v_xp int := 0; mins int; msg text;
  a_army jsonb; d_army jsonb; fa numeric; fd numeric;
  a_lp numeric; d_lp numeric; a_w1 int; a_w2 int; d_w1 int; d_w2 int; a_lost int := 0; d_lost int := 0; d_note text := '';
begin
  if p_target is null or p_target = pid then raise exception 'You cannot attack yourself.'; end if;
  if not exists (select 1 from game.players where id = p_target) then raise exception 'Target not found.'; end if;
  -- lock both rows in a fixed order to avoid deadlocks / double-spends
  if pid < p_target then a := game.tick(pid); d := game.tick(p_target);
  else d := game.tick(p_target); a := game.tick(pid); end if;

  perform game.require_free(a);
  a_disp := case when a.is_admin then 'Command HQ' else a.username end;
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

  -- Command Powers
  if a.god_strike and d_hp > 0 then
    d_hp := 0; a_hp := greatest(a_hp, 1);
    v_log := v_log || format('GOD STRIKE: Command artillery obliterates %s.', d.username);
  end if;
  if a.immortal and a_hp <= 0 then
    a_hp := 1;
    v_log := v_log || format('%s is shielded by Command immunity and withdraws.', a.username);
  end if;

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
      perform game.add_event(d.id, 'battle', format('%s attacked you and won. You lost $%s and were hospitalized for %s minutes.', a_disp, v_cash, mins));
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
      perform game.add_event(d.id, 'battle', format('%s attacked you and lost. You held your ground!', a_disp));
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
      perform game.add_event(d.id, 'battle', format('%s attacked you but withdrew after a stalemate.', a_disp));
    end if;
    msg := format('Stalemate. Neither side broke, and you withdrew from %s.', d.username);
    v_log := v_log || 'Both sides withdraw.';
  end if;

  -- Casualties and vehicle wear (NPC forces always regroup)
  if outcome = 'win' then a_lp := 0.01 + random() * 0.03; d_lp := 0.06 + random() * 0.06; a_w1 := 1; a_w2 := 5; d_w1 := 4; d_w2 := 10;
  elsif outcome = 'loss' then a_lp := 0.06 + random() * 0.06; d_lp := 0.01 + random() * 0.03; a_w1 := 4; a_w2 := 10; d_w1 := 1; d_w2 := 5;
  else a_lp := 0.02 + random() * 0.03; d_lp := 0.02 + random() * 0.03; a_w1 := 2; a_w2 := 6; d_w1 := 2; d_w2 := 6; end if;
  if a.immortal or a.god_strike then a_lp := 0; a_w1 := 0; a_w2 := 0; end if;
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

create or replace function public.list_players(p_token text, p_search text default null, p_page int default 0) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); q text := nullif(trim(coalesce(p_search, '')), '');
begin
  if q is not null then q := regexp_replace(q, '[^A-Za-z0-9_ ]', '', 'g'); end if;
  return coalesce((select jsonb_agg(game.public_player(x) order by x.level desc, x.id) from (
      select * from game.players p
       where not p.is_admin and (q is null or p.username ilike '%' || q || '%')
       order by p.level desc, p.id
       limit 25 offset greatest(0, least(coalesce(p_page, 0), 1000)) * 25) x), '[]'::jsonb);
end $$;

create or replace function public.get_profile(p_token text, p_player bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players;
begin
  select * into p from game.players where id = p_player;
  if not found or (p.is_admin and not exists (select 1 from game.players where id = pid and is_admin)) then
    raise exception 'Soldier not found.';
  end if;
  return game.public_player(p);
end $$;

create or replace function public.hospital_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'username', username, 'level', level,
            'until', hospital_until) order by hospital_until)
     from (select id, username, level, hospital_until from game.players
            where hospital_until > now() and not is_npc and not banned and not is_admin order by hospital_until limit 50) x), '[]'::jsonb);
end $$;

create or replace function public.get_chat(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'player_id', case when p.is_admin then null else c.player_id end,
            'username', case when p.is_admin then 'Command HQ' else p.username end,
            'staff', p.is_admin, 'message', c.message, 'created_at', c.created_at) order by c.id)
     from (select * from game.chat_messages order by id desc limit 50) c
     join game.players p on p.id = c.player_id), '[]'::jsonb);
end $$;

create or replace function public.get_faction(p_token text, p_faction bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); f game.factions;
begin
  select * into f from game.factions where id = p_faction;
  if not found then raise exception 'Army not found.'; end if;
  return jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag, 'description', f.description,
    'leader_id', f.leader_id, 'created_at', f.created_at::date,
    'members', coalesce((select jsonb_agg(game.public_player(p) order by p.level desc) from game.players p where p.faction_id = f.id and not p.is_admin), '[]'::jsonb));
end $$;

create or replace function public.list_factions(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'tag', f.tag,
            'description', f.description, 'leader', (select case when is_admin then 'Command HQ' else username end from game.players where id = f.leader_id),
            'members', (select count(*) from game.players where faction_id = f.id),
            'total_level', (select coalesce(sum(level), 0) from game.players where faction_id = f.id)) order by f.id)
     from game.factions f), '[]'::jsonb);
end $$;

create or replace function public.join_faction(p_token text, p_faction bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; f game.factions;
begin
  select * into f from game.factions where id = p_faction for update;
  if not found then raise exception 'Army not found.'; end if;
  p := game.tick(pid);
  if p.faction_id is not null then raise exception 'Leave your current army first.'; end if;
  if (select count(*) from game.players where faction_id = f.id) >= 50 then raise exception 'That army is full (50 members).'; end if;
  update game.players set faction_id = f.id where id = pid;
  perform game.add_event(pid, 'faction', format('You enlisted in %s [%s].', f.name, f.tag));
  if f.leader_id is not null then
    perform game.add_event(f.leader_id, 'faction', format('%s enlisted in your army.', case when p.is_admin then 'Command HQ' else p.username end));
  end if;
  return jsonb_build_object('message', format('You joined %s.', f.name));
end $$;

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
    'troops', p.troops, 'max_troops', game.max_troops(p.level), 'troops_cap', 1000,
    'troops_free_granted', p.troops_free_granted, 'free_troops_cap', 300,
    'immortal', p.immortal, 'god_strike', p.god_strike,
    'force_class', game.force_class((game.army_power(p.id)->>'power')::numeric),
    'wins', p.wins, 'losses', p.losses, 'missions_done', p.missions_done,
    'server_time', now()
  ) from game.players p where p.id = pid $$;


-- ===== Command Powers: admin-only actions on the admin's OWN account =====

create or replace function public.admin_power_refill(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.require_admin(pid);
  perform game.tick(pid);
  update game.players set energy = 100, nerve = 10, hp = game.max_hp(level),
    energy_at = now(), nerve_at = now(), hp_at = now() where id = pid;
  perform game.audit(pid, 'power: refill', pid);
  return jsonb_build_object('message', 'Energy, nerve and health fully restored.', 'me', game.me_json(pid));
end $$;

create or replace function public.admin_power_release(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.require_admin(pid);
  perform game.tick(pid);
  update game.players set hospital_until = null, jail_until = null, hp = game.max_hp(level), hp_at = now() where id = pid;
  perform game.audit(pid, 'power: release', pid);
  return jsonb_build_object('message', 'Released from hospital and stockade.', 'me', game.me_json(pid));
end $$;

create or replace function public.admin_power_set_stats(p_token text, p_str numeric default null, p_def numeric default null,
  p_spd numeric default null, p_dex numeric default null, p_level int default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; ft int := 0;
begin
  perform game.require_admin(pid);
  if (p_str is not null and (p_str < 0 or p_str > 1e9)) or (p_def is not null and (p_def < 0 or p_def > 1e9))
     or (p_spd is not null and (p_spd < 0 or p_spd > 1e9)) or (p_dex is not null and (p_dex < 0 or p_dex > 1e9)) then
    raise exception 'Stats must be between 0 and 1,000,000,000.';
  end if;
  if p_level is not null and (p_level < 1 or p_level > 100) then raise exception 'Level must be 1-100.'; end if;
  p := game.tick(pid);
  update game.players set
    str = coalesce(round(p_str, 2), str), def = coalesce(round(p_def, 2), def),
    spd = coalesce(round(p_spd, 2), spd), dex = coalesce(round(p_dex, 2), dex),
    level = coalesce(p_level, level),
    xp = case when p_level is null then xp when p_level = 1 then 0 else game.xp_for(p_level - 1) end,
    hp = game.max_hp(coalesce(p_level, level)), hp_at = now()
  where id = pid;
  if p_level is not null and p_level > p.level then ft := game.grant_level_troops(pid, p_level - p.level); end if;
  perform game.audit(pid, 'power: set stats', pid, jsonb_build_object('str', p_str, 'def', p_def, 'spd', p_spd, 'dex', p_dex, 'level', p_level));
  return jsonb_build_object('message', 'Stats updated.' || case when ft > 0 then format(' +%s level-up troops.', ft) else '' end, 'me', game.me_json(pid));
end $$;

create or replace function public.admin_power_grant(p_token text, p_cash bigint default 0, p_troops int default 0,
  p_weapon int default null, p_weapon_qty int default 0, p_vehicle int default null, p_vehicle_qty int default 0) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); p game.players; n int; parts text[] := '{}';
begin
  perform game.require_admin(pid);
  p := game.tick(pid);
  p_cash := coalesce(p_cash, 0); p_troops := coalesce(p_troops, 0); p_weapon_qty := coalesce(p_weapon_qty, 0); p_vehicle_qty := coalesce(p_vehicle_qty, 0);
  if p_cash < 0 or p_cash > 1000000000000 then raise exception 'Cash grant must be 0 to 1,000,000,000,000.'; end if;
  if p_troops < 0 or p.troops + p_troops > 1000 then raise exception 'Army size is capped at 1,000 troops (you have %).', p.troops; end if;
  if p_weapon_qty < 0 or p_weapon_qty > 1000 then raise exception 'Weapon quantity must be 0-1,000.'; end if;
  if p_vehicle_qty < 0 or p_vehicle_qty > 20 then raise exception 'Vehicle quantity must be 0-20.'; end if;
  if p_cash > 0 then update game.players set cash = cash + p_cash where id = pid; parts := parts || format('$%s', p_cash); end if;
  if p_troops > 0 then update game.players set troops = troops + p_troops where id = pid; parts := parts || format('%s troops', p_troops); end if;
  if p_weapon_qty > 0 then
    if not exists (select 1 from game.troop_weapons where id = p_weapon) then raise exception 'Unknown army weapon.'; end if;
    if coalesce((select qty from game.player_troop_weapons where player_id = pid and weapon_id = p_weapon), 0) + p_weapon_qty > 1000 then
      raise exception 'At most 1,000 of each army weapon.';
    end if;
    insert into game.player_troop_weapons (player_id, weapon_id, qty) values (pid, p_weapon, p_weapon_qty)
      on conflict (player_id, weapon_id) do update set qty = game.player_troop_weapons.qty + excluded.qty;
    parts := parts || format('%s x %s', p_weapon_qty, (select name from game.troop_weapons where id = p_weapon));
  end if;
  if p_vehicle_qty > 0 then
    if not exists (select 1 from game.vehicles where id = p_vehicle) then raise exception 'Unknown vehicle.'; end if;
    select count(*) into n from game.player_vehicles where player_id = pid and vehicle_id = p_vehicle;
    if n + p_vehicle_qty > 20 then raise exception 'At most 20 of each vehicle.'; end if;
    insert into game.player_vehicles (player_id, vehicle_id) select pid, p_vehicle from generate_series(1, p_vehicle_qty);
    parts := parts || format('%s x %s', p_vehicle_qty, (select name from game.vehicles where id = p_vehicle));
  end if;
  if cardinality(parts) = 0 then raise exception 'Nothing to grant.'; end if;
  perform game.audit(pid, 'power: grant self', pid, jsonb_build_object('cash', p_cash, 'troops', p_troops,
    'weapon', p_weapon, 'weapon_qty', p_weapon_qty, 'vehicle', p_vehicle, 'vehicle_qty', p_vehicle_qty));
  return jsonb_build_object('message', 'Granted: ' || array_to_string(parts, ', ') || '.', 'me', game.me_json(pid));
end $$;

create or replace function public.admin_power_toggle(p_token text, p_power text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.require_admin(pid);
  if p_power not in ('immortal','god_strike') then raise exception 'Unknown power.'; end if;
  perform game.tick(pid);
  update game.players set
    immortal = case when p_power = 'immortal' then coalesce(p_on, false) else immortal end,
    god_strike = case when p_power = 'god_strike' then coalesce(p_on, false) else god_strike end,
    hospital_until = case when p_power = 'immortal' and p_on then null else hospital_until end,
    jail_until = case when p_power = 'immortal' and p_on then null else jail_until end
  where id = pid;
  perform game.audit(pid, format('power: %s %s', p_power, case when p_on then 'on' else 'off' end), pid);
  return jsonb_build_object('message', format('%s is now %s.', case when p_power = 'immortal' then 'Immortal' else 'God strike' end,
                                              case when p_on then 'ON' else 'OFF' end), 'me', game.me_json(pid));
end $$;

create or replace function public.admin_command_order(p_token text, p_message text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token); m text := trim(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g')); n int;
begin
  perform game.require_admin(pid);
  if length(m) < 1 or length(m) > 300 then raise exception 'Command Orders must be 1-300 characters.'; end if;
  if exists (select 1 from game.admin_audit_log where admin_id = pid and action = 'command order' and created_at > now() - interval '30 seconds') then
    raise exception 'Wait 30 seconds between Command Orders.';
  end if;
  insert into game.events (player_id, kind, message)
    select id, 'order', 'COMMAND ORDER: ' || m from game.players where not is_npc and not banned;
  get diagnostics n = row_count;
  perform game.audit(pid, 'command order', null, jsonb_build_object('message', m, 'recipients', n));
  return jsonb_build_object('message', format('Command Order sent to %s soldiers.', n));
end $$;

create or replace function public.admin_audit_log_list(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  perform game.require_admin(pid);
  return coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'admin', a.username, 'action', l.action,
            'target', t.username, 'details', l.details, 'created_at', l.created_at) order by l.id desc)
     from (select * from game.admin_audit_log order by id desc limit 200) l
     left join game.players a on a.id = l.admin_id left join game.players t on t.id = l.target_id), '[]'::jsonb);
end $$;

revoke all on all functions in schema game from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
