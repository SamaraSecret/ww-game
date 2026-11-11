-- World War: text-based multiplayer game. Schema.
-- All game tables live in the private "game" schema, which is NOT exposed by the API.
-- Clients can only call the SECURITY DEFINER functions in "public" (RPC).

create schema if not exists game;
revoke all on schema game from public;
revoke all on schema game from anon, authenticated;

create table game.items (
  id int primary key,
  name text not null,
  kind text not null check (kind in ('weapon','armor')),
  power int not null check (power >= 0),
  price bigint not null check (price > 0),
  min_level int not null default 1,
  description text not null default ''
);

create table game.missions (
  id int primary key,
  name text not null,
  description text not null,
  tier int not null,
  nerve_cost int not null check (nerve_cost > 0),
  min_level int not null default 1,
  base_chance numeric not null,
  cash_min bigint not null,
  cash_max bigint not null,
  xp int not null,
  success_text text not null,
  fail_text text not null
);

create table game.factions (
  id bigint generated always as identity primary key,
  name text not null,
  tag text not null,
  description text not null default '',
  leader_id bigint,
  created_at timestamptz not null default now()
);
create unique index factions_name_uq on game.factions (lower(name));
create unique index factions_tag_uq on game.factions (lower(tag));

create table game.players (
  id bigint generated always as identity primary key,
  username text not null,
  pass_hash text,                 -- bcrypt hash; NULL for NPCs (cannot log in)
  is_admin boolean not null default false,
  is_npc boolean not null default false,
  banned boolean not null default false,
  level int not null default 1,
  xp bigint not null default 0 check (xp >= 0),
  cash bigint not null default 1000 check (cash >= 0),
  bank bigint not null default 0 check (bank >= 0),
  hp int not null default 100,
  energy int not null default 100,
  nerve int not null default 10,
  hp_at timestamptz not null default now(),
  energy_at timestamptz not null default now(),
  nerve_at timestamptz not null default now(),
  str numeric(14,2) not null default 10,
  def numeric(14,2) not null default 10,
  spd numeric(14,2) not null default 10,
  dex numeric(14,2) not null default 10,
  weapon_id int references game.items(id),
  armor_id int references game.items(id),
  hospital_until timestamptz,
  jail_until timestamptz,
  faction_id bigint references game.factions(id) on delete set null,
  wins int not null default 0,
  losses int not null default 0,
  missions_done int not null default 0,
  failed_logins int not null default 0,
  locked_until timestamptz,
  last_chat_at timestamptz,
  last_action timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create unique index players_username_uq on game.players (lower(username));
create index players_faction_idx on game.players (faction_id);
alter table game.factions add constraint factions_leader_fk
  foreign key (leader_id) references game.players(id) on delete set null;

create table game.sessions (
  token_hash bytea primary key,   -- sha256 of the token; the raw token is never stored
  player_id bigint not null references game.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index sessions_player_idx on game.sessions (player_id);

create table game.inventory (
  player_id bigint not null references game.players(id) on delete cascade,
  item_id int not null references game.items(id),
  qty int not null check (qty > 0),
  primary key (player_id, item_id)
);

create table game.events (
  id bigint generated always as identity primary key,
  player_id bigint not null references game.players(id) on delete cascade,
  kind text not null,
  message text not null,
  seen boolean not null default false,
  created_at timestamptz not null default now()
);
create index events_player_idx on game.events (player_id, id desc);

create table game.chat_messages (
  id bigint generated always as identity primary key,
  player_id bigint not null references game.players(id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now()
);

create table game.announcements (
  id bigint generated always as identity primary key,
  message text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table game.attacks (
  id bigint generated always as identity primary key,
  attacker_id bigint not null references game.players(id) on delete cascade,
  defender_id bigint not null references game.players(id) on delete cascade,
  result text not null,
  created_at timestamptz not null default now()
);
create index attacks_pair_idx on game.attacks (attacker_id, defender_id, created_at desc);
create index attacks_def_idx on game.attacks (defender_id);

create table game.admin_log (
  id bigint generated always as identity primary key,
  admin_id bigint references game.players(id) on delete set null,
  target_id bigint references game.players(id) on delete set null,
  action text not null,
  created_at timestamptz not null default now()
);
create index admin_log_admin_idx on game.admin_log (admin_id);
create index admin_log_target_idx on game.admin_log (target_id);
create index chat_player_idx on game.chat_messages (player_id);
create index players_weapon_idx on game.players (weapon_id);
create index players_armor_idx on game.players (armor_id);
create index inventory_item_idx on game.inventory (item_id);
create index factions_leader_idx on game.factions (leader_id);

-- Lock everything down: RLS on, no policies, no table privileges for API roles.
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'game' loop
    execute format('alter table game.%I enable row level security', t);
    execute format('revoke all on table game.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on all sequences in schema game from public, anon, authenticated;
