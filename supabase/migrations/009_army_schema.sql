-- Army Command: troops, troop weapons, vehicles.

alter table game.players add column if not exists troops int not null default 0 check (troops >= 0);

create table game.troop_weapons (
  id int primary key,
  name text not null,
  attack int not null check (attack >= 0),
  defense int not null check (defense >= 0),
  price bigint not null check (price > 0),
  min_level int not null default 1,
  description text not null default ''
);

create table game.player_troop_weapons (
  player_id bigint not null references game.players(id) on delete cascade,
  weapon_id int not null references game.troop_weapons(id),
  qty int not null check (qty > 0),
  primary key (player_id, weapon_id)
);
create index ptw_weapon_idx on game.player_troop_weapons (weapon_id);

create table game.vehicles (
  id int primary key,
  name text not null,
  attack int not null check (attack >= 0),
  defense int not null check (defense >= 0),
  price bigint not null check (price > 0),
  min_level int not null default 1,
  description text not null default ''
);

create table game.player_vehicles (
  id bigint generated always as identity primary key,
  player_id bigint not null references game.players(id) on delete cascade,
  vehicle_id int not null references game.vehicles(id),
  condition int not null default 100 check (condition between 0 and 100),
  created_at timestamptz not null default now()
);
create index pv_player_idx on game.player_vehicles (player_id, vehicle_id);
create index pv_vehicle_idx on game.player_vehicles (vehicle_id);

do $$
declare t text;
begin
  foreach t in array array['troop_weapons','player_troop_weapons','vehicles','player_vehicles'] loop
    execute format('alter table game.%I enable row level security', t);
    execute format('revoke all on table game.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on all sequences in schema game from public, anon, authenticated;
