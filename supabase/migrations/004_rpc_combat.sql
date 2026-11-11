-- Public RPCs: battlefield and combat.

create or replace function public.list_targets(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pid bigint := game.auth(p_token);
begin
  return coalesce((select jsonb_agg(t order by t->>'npc' desc, (t->>'level')::int) from (
    select jsonb_build_object(
      'id', p.id, 'username', p.username, 'level', p.level, 'rank', game.rank_title(p.level),
      'npc', p.is_npc, 'status', case when p.is_npc then 'Okay' else game.status_of(p.hospital_until, p.jail_until) end,
      'faction', (select f.tag from game.factions f where f.id = p.faction_id),
      'protected', (not p.is_npc and p.level < 3),
      'cooldown', (select greatest(0, ceil(extract(epoch from (a.created_at + interval '10 minutes' - now()))))::int
                     from game.attacks a where a.attacker_id = pid and a.defender_id = p.id and not p.is_npc
                    order by a.created_at desc limit 1)
    ) t
    from game.players p
    where p.id <> pid and not p.banned and not p.is_admin and (p.is_npc or p.level >= 3)
    order by p.is_npc desc, p.level limit 60) x), '[]'::jsonb);
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
  outcome text; v_cash bigint := 0; v_xp int := 0; mins int; msg text;
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

  a_hp := a.hp; d_hp := case when d.is_npc then d_max else d.hp end;
  a_first := a.spd * (0.8 + random() * 0.4) >= d.spd * (0.8 + random() * 0.4);
  v_log := v_log || format('%s engages %s. %s moves first.', a.username, d.username,
                       case when a_first then a.username else d.username end);

  <<rounds>>
  for r in 1..12 loop
    for s in 0..1 loop
      atk_is_a := (s = 0) = a_first;
      if atk_is_a then
        chance := least(0.95, greatest(0.25, a.spd / (a.spd + d.dex) * 1.1 + 0.05));
        if random() < chance then
          crit := random() < 0.15;
          dmg := greatest(1, round((10 + a.str * 0.8 + a_wp) * (0.8 + random() * 0.4)
                         * (100.0 / (100.0 + d.def * 0.5 + d_ap * 2)) * case when crit then 1.5 else 1 end));
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
                         * (100.0 / (100.0 + a.def * 0.5 + a_ap * 2)) * case when crit then 1.5 else 1 end));
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

  insert into game.attacks (attacker_id, defender_id, result) values (pid, d.id, outcome);
  perform game.add_event(pid, 'battle', msg);
  return jsonb_build_object('result', outcome, 'message', msg, 'log', to_jsonb(v_log),
                            'cash', v_cash, 'xp', v_xp, 'me', game.me_json(pid));
end $$;
