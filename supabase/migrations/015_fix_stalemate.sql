-- Fix: stalemate battles failed with 'malformed array literal'.

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
    v_log := v_log || 'Both sides withdraw.'::text;
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

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
