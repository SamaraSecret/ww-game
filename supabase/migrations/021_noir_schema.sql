-- Noir Syndicate: convert the war game into an original underworld crime RPG.
-- Keeps accounts, sessions, auth helpers, rate limits and the admin user.
-- Replaces war catalogs and adds crime, cartel, garage, fronts, raids and bounty tables.

-- ---------------------------------------------------------------------------
-- 1. Player columns (cash remains dirty pocket money)
-- ---------------------------------------------------------------------------
alter table game.players add column if not exists clean_cash bigint not null default 0;
alter table game.players drop constraint if exists players_clean_cash_nonneg;
alter table game.players add constraint players_clean_cash_nonneg check (clean_cash >= 0);

alter table game.players add column if not exists specialization text;
alter table game.players drop constraint if exists players_specialization_chk;
alter table game.players add constraint players_specialization_chk
  check (specialization is null or specialization in ('enforcer','hustler','fixer','ghost'));

alter table game.players add column if not exists last_steal_at timestamptz;
alter table game.players add column if not exists last_hit_at timestamptz;
alter table game.players add column if not exists last_break_at timestamptz;
alter table game.players add column if not exists last_path_at timestamptz;
alter table game.players add column if not exists last_economy_at timestamptz not null default now();
alter table game.players add column if not exists crimes_done int not null default 0;
alter table game.players add column if not exists last_export_at timestamptz;
alter table game.players add column if not exists path_buff text;
alter table game.players add column if not exists path_buff_until timestamptz;

-- Carry existing mission counts across, then keep both in sync going forward.
update game.players set crimes_done = greatest(crimes_done, missions_done);

-- ---------------------------------------------------------------------------
-- 2. Cartel (faction) vaults
-- ---------------------------------------------------------------------------
alter table game.factions add column if not exists vault_dirty bigint not null default 0;
alter table game.factions add column if not exists vault_clean bigint not null default 0;
alter table game.factions drop constraint if exists factions_vault_dirty_nonneg;
alter table game.factions add constraint factions_vault_dirty_nonneg check (vault_dirty >= 0);
alter table game.factions drop constraint if exists factions_vault_clean_nonneg;
alter table game.factions add constraint factions_vault_clean_nonneg check (vault_clean >= 0);

-- ---------------------------------------------------------------------------
-- 3. Reset war inventories (only admin + NPCs exist besides leftover tests)
-- ---------------------------------------------------------------------------
update game.players set weapon_id = null, armor_id = null;
delete from game.inventory;
delete from game.player_troop_weapons;
delete from game.player_vehicles;

-- ---------------------------------------------------------------------------
-- 4. Personal weapons and armor
-- ---------------------------------------------------------------------------
delete from game.items;
alter table game.items drop constraint if exists items_icon_chk;
-- icon stays as text; frontend validates slugs

insert into game.items (id, name, kind, power, price, min_level, description, icon) values
 (1,  'Brass Knuckles',    'weapon',   4,     250,  1, 'A pocket full of bad intentions.', 'brass-knuckles'),
 (2,  'Folding Blade',     'weapon',   6,     500,  1, 'Small enough to vanish, sharp enough to matter.', 'folding-blade'),
 (3,  'Lead Pipe',         'weapon',   8,     900,  1, 'Cut short and ugly. It never needs a license.', 'lead-pipe'),
 (4,  'Hardwood Bat',      'weapon',  10,    1500,  2, 'A former sport, now a conversation ender.', 'hardwood-bat'),
 (5,  'Crowbar',           'weapon',  12,    2500,  3, 'Opens doors, locks and arguments.', 'crowbar'),
 (6,  'Snub Revolver',     'weapon',  16,    4500,  3, 'A short barrel for close, unfriendly work.', 'snub-revolver'),
 (7,  'Pocket Pistol',     'weapon',  20,    8000,  4, 'Hides under a coat and talks in short sentences.', 'pocket-pistol'),
 (8,  'Service Pistol',    'weapon',  26,   14000,  6, 'A full-size sidearm with no name on the slide.', 'service-pistol'),
 (9,  'Sawed-Off',         'weapon',  32,   22000,  7, 'Two short barrels. No long explanations.', 'sawed-off'),
 (10, 'Pump Shotgun',      'weapon',  38,   35000,  9, 'The sound alone clears a hallway.', 'pump-shotgun'),
 (11, 'Machine Pistol',    'weapon',  44,   50000, 11, 'A compact spray for tight rooms.', 'machine-pistol'),
 (12, 'Street SMG',        'weapon',  50,   75000, 13, 'Folding stock, short bursts, long nights.', 'street-smg'),
 (13, 'Hunting Rifle',     'weapon',  56,  110000, 15, 'Built for game. Used for something else.', 'hunting-rifle'),
 (14, 'Short Carbine',     'weapon',  64,  160000, 17, 'A chopped rifle that still hits hard.', 'short-carbine'),
 (15, 'Silent Pistol',     'weapon',  70,  220000, 19, 'A long can on the end. The room stays quiet.', 'silent-pistol'),
 (16, 'Riot Shotgun',      'weapon',  78,  300000, 21, 'Pistol grip, heat shield, no patience.', 'riot-shotgun'),
 (17, 'Marksman Rifle',    'weapon',  86,  420000, 23, 'A compact scope for careful work across a street.', 'marksman-rifle'),
 (18, 'Automatic Rifle',   'weapon',  96,  600000, 26, 'A full magazine and a short temper.', 'automatic-rifle'),
 (19, 'Long Rifle',        'weapon', 110,  850000, 30, 'A long barrel and a longer shadow.', 'long-rifle'),
 (20, 'Heavy Custom',      'weapon', 128, 1250000, 35, 'Engraved, oversized, and unmistakable.', 'heavy-custom'),
 (101,'Cloth Coat',        'armor',    3,     400,  1, 'Worn wool that turns a little weather and a little blade.', 'cloth-coat'),
 (102,'Leather Jacket',    'armor',    6,    1500,  1, 'Thick hide. Looks like it has already been through a fight.', 'leather-jacket'),
 (103,'Stab Vest',         'armor',   10,    5000,  4, 'Quiet fabric panels that take a knife so you do not.', 'stab-vest'),
 (104,'Motorcycle Jacket', 'armor',   14,   12000,  7, 'Padded shoulders and elbows for a hard landing.', 'motorcycle-jacket'),
 (105,'Trench Coat',       'armor',   18,   28000, 10, 'A long coat that hides more than rain.', 'trench-coat'),
 (106,'Ballistic Vest',    'armor',   24,   55000, 14, 'Hard plates under a plain shell.', 'ballistic-vest'),
 (107,'Armored Overcoat',  'armor',   32,  110000, 18, 'A heavy coat with plates stitched into the lining.', 'armored-overcoat'),
 (108,'Tactical Rig',      'armor',   42,  200000, 24, 'A full rig of plates, pads and pouches.', 'tactical-rig');

-- ---------------------------------------------------------------------------
-- 5. Crimes (replaces missions catalog)
-- ---------------------------------------------------------------------------
create table if not exists game.crimes (
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
delete from game.crimes;
insert into game.crimes (id, name, description, tier, nerve_cost, min_level, base_chance, cash_min, cash_max, xp, success_text, fail_text) values
 (1, 'Pickpocket',        'Lift a wallet on a crowded Grayhaven sidewalk.',                 1, 1,  1, 0.78,    40,    140,   6,
     'You fade into the crowd with a fat wallet.', 'A hand closed on your wrist before you could vanish.'),
 (2, 'Shoplift',          'Walk a few unpaid goods out of a corner store.',                 2, 2,  2, 0.68,   140,    400,  14,
     'The clerk never looked up. The bag is yours.', 'A bell rang and a clerk blocked the door.'),
 (3, 'Burglary',          'Slip a quiet apartment while the lights are out.',               3, 3,  4, 0.58,   400,   1100,  26,
     'You left with jewelry and a thick envelope.', 'A neighbor saw the open window and called it in.'),
 (4, 'Car Boost',         'Hot-wire a parked ride and strip the easy cash from it.',        4, 4,  6, 0.50,  1100,   2600,  45,
     'You dumped the ride in an alley and kept the cash.', 'A patrol rolled up before the engine caught.'),
 (5, 'Armed Robbery',     'Walk into a late counter with a weapon showing.',                5, 5,  9, 0.44,  2500,   6000,  80,
     'The till is empty and you are already gone.', 'A silent alarm went first. You ran into waiting lights.'),
 (6, 'Armored Job',       'Hit a moving cash box on a side street.',                        6, 6, 12, 0.40,  5000,  11000, 110,
     'The box cracked. Dirty cash filled the bag.', 'The escort returned fire and you had to drop it.'),
 (7, 'Estate Lift',       'Empty a hill house while the owners are at a dinner.',           7, 7, 16, 0.36,  8000,  17000, 150,
     'Silver, papers and a safe. A clean night''s work.', 'A silent sensor caught you in the hall.'),
 (8, 'Night Vault',       'Crack a private vault after hours.',                             8, 8, 20, 0.32, 14000,  30000, 200,
     'The vault door sighed open. You left heavier than you arrived.', 'The floor went loud and the exits closed.');

-- Keep missions table empty so leftover RPCs cannot serve war text if any remain briefly.
delete from game.missions;

-- ---------------------------------------------------------------------------
-- 6. Crew weapons
-- ---------------------------------------------------------------------------
delete from game.troop_weapons;
insert into game.troop_weapons (id, name, attack, defense, price, min_level, description, icon) values
 (1, 'Street Pistols',  2, 1,   80,  1, 'A crate of cheap sidearms for your crew.', 'service-pistol'),
 (2, 'SMG Crates',      4, 1,  200,  5, 'Short guns for tight street work.', 'street-smg'),
 (3, 'Shotgun Crates',  5, 2,  400,  8, 'Wide patterns for doorways and alleys.', 'pump-shotgun'),
 (4, 'Rifle Crates',    7, 2,  800, 12, 'Longer reach for a crew that holds a corner.', 'hunting-rifle'),
 (5, 'Molotovs',        9, 1, 1500, 16, 'Glass, rags and a short fuse.', 'molotovs'),
 (6, 'Light Autos',    11, 3, 2800, 20, 'Automatic rifles for a serious crew.', 'automatic-rifle'),
 (7, 'Pipe Bombs',     14, 2, 5000, 25, 'Capped pipe and a length of fuse.', 'pipe-bombs'),
 (8, 'Heavy Rifles',   18, 4, 9000, 30, 'The last word in a turf fight.', 'long-rifle');

-- ---------------------------------------------------------------------------
-- 7. Getaway cars (reuse vehicles catalog; no longer bought from a shop)
-- ---------------------------------------------------------------------------
-- Drop war-era columns we no longer need after emptying player_vehicles.
alter table game.vehicles add column if not exists difficulty int not null default 1;
alter table game.vehicles add column if not exists chop_value bigint not null default 100;
alter table game.vehicles add column if not exists export_value bigint not null default 200;
alter table game.vehicles add column if not exists steal_energy int not null default 15;
alter table game.player_vehicles add column if not exists tune_level int not null default 0;
alter table game.player_vehicles drop constraint if exists player_vehicles_tune_chk;
alter table game.player_vehicles add constraint player_vehicles_tune_chk check (tune_level between 0 and 5);

delete from game.vehicles;
insert into game.vehicles (id, name, attack, defense, price, min_level, description, icon,
                           difficulty, chop_value, export_value, steal_energy) values
 (1,  'Beater Sedan',       0,0,1,  1, 'A rusted four-door that still starts, sometimes.', 'beater-sedan',       1,   400,   900, 12),
 (2,  'Compact Hatch',      0,0,1,  1, 'Small, quiet and easy to lose in traffic.', 'compact-hatch',      1,   500,  1200, 12),
 (3,  'City Taxi',          0,0,1,  2, 'Nobody looks twice at a cab after midnight.', 'city-taxi',          2,   700,  1700, 14),
 (4,  'Pickup Truck',       0,0,1,  3, 'An open bed for cargo you should not describe.', 'pickup-truck',       2,   900,  2200, 14),
 (5,  'Street Motorcycle',  0,0,1,  2, 'Fast in an alley. Gone before a light turns.', 'street-motorcycle',  2,   800,  2100, 13),
 (6,  'Muscle Coupe',       0,0,1,  4, 'A long hood and a louder exit.', 'muscle-coupe',       3,  1400,  3600, 16),
 (7,  'Panel Van',          0,0,1,  4, 'No windows, no questions.', 'panel-van',          3,  1300,  3400, 16),
 (8,  'Family SUV',         0,0,1,  5, 'Looks ordinary. Holds a lot.', 'family-suv',         3,  1600,  4200, 16),
 (9,  'Luxury Sedan',       0,0,1,  6, 'Quiet doors and a heavy, expensive silence.', 'luxury-sedan',       4,  2800,  7500, 18),
 (10, 'Tow Truck',          0,0,1,  6, 'If you can hook it, you can move it.', 'tow-truck',          4,  2400,  6400, 18),
 (11, 'Box Truck',          0,0,1,  7, 'A rolling room with a roll-up door.', 'box-truck',          4,  2600,  7000, 18),
 (12, 'Stretch Limo',       0,0,1,  8, 'Too long to hide, too rich to ignore.', 'stretch-limo',       5,  4000, 11000, 20),
 (13, 'Sports Bike',        0,0,1,  8, 'A low fairing and almost no second chance.', 'sports-bike',        5,  3600,  9800, 18),
 (14, 'Getaway Coupe',      0,0,1,  9, 'Matte, mean, and built to leave first.', 'getaway-coupe',      5,  4500, 12500, 20),
 (15, 'Classic Coupe',      0,0,1, 10, 'Running boards, a rounded fender, and a story.', 'classic-coupe',     6,  5200, 15000, 20),
 (16, 'Work Boat',          0,0,1, 11, 'A small hull for a quiet trip out of the docks.', 'work-boat',         6,  5800, 17000, 22),
 (17, 'Sports Coupe',       0,0,1, 12, 'Low, sleek, and hard to catch on a straight.', 'sports-coupe',      6,  7000, 20000, 22),
 (18, 'Night Lowrider',     0,0,1, 13, 'Sits close to the street and owns it.', 'night-lowrider',     7,  8500, 24000, 22),
 (19, 'Armored SUV',        0,0,1, 14, 'Thick doors and darker glass.', 'armored-suv',       8, 12000, 34000, 24),
 (20, 'Exotic',             0,0,1, 20, 'A sculpted mid-engine prize. The docks pay well.', 'exotic',            9, 20000, 60000, 28);

-- ---------------------------------------------------------------------------
-- 8. Businesses, districts, bounties, raids, swiss CDs
-- ---------------------------------------------------------------------------
create table if not exists game.business_types (
  id int primary key,
  name text not null,
  description text not null,
  price bigint not null check (price > 0),
  min_level int not null default 1,
  launder_per_hour bigint not null check (launder_per_hour > 0),
  fee_bps int not null check (fee_bps between 0 and 9000),
  icon text not null
);
delete from game.business_types;
insert into game.business_types (id, name, description, price, min_level, launder_per_hour, fee_bps, icon) values
 (1,  'Coin Laundry',       'Washers run all night. So does the cash.',                  8000,  1,   400, 2500, 'coin-laundry'),
 (2,  'Liquor Store',       'A barred window and a helpful back room.',                 15000,  3,   800, 2200, 'liquor-store'),
 (3,  'Corner Diner',       'Coffee up front. Ledgers in the booth by the window.',     25000,  5,  1200, 2000, 'corner-diner'),
 (4,  'Pawn Shop',          'Tickets in, envelopes out.',                               40000,  7,  2000, 1800, 'pawn-shop'),
 (5,  'Car Wash',           'Everything comes out cleaner than it went in.',            70000, 10,  3500, 1600, 'car-wash'),
 (6,  'Roadside Motel',     'Rooms by the hour, books by the week.',                   120000, 13,  5500, 1500, 'roadside-motel'),
 (7,  'Nightclub',          'A dark door, a loud floor, a quiet office.',              200000, 16,  9000, 1400, 'nightclub'),
 (8,  'Warehouse',          'A loading dock that never asks what is in the crates.',   350000, 20, 15000, 1200, 'warehouse'),
 (9,  'Construction Front', 'A yard, a shack, and invoices for work that never happened.', 600000, 25, 25000, 1000, 'construction-front'),
 (10, 'Social Club',        'Members only. The ledgers are older than the wine.',     1000000, 30, 40000,  800, 'social-club');

create table if not exists game.player_businesses (
  player_id bigint not null references game.players(id) on delete cascade,
  business_id int not null references game.business_types(id),
  bought_at timestamptz not null default now(),
  last_run_at timestamptz not null default now(),
  primary key (player_id, business_id)
);
create index if not exists player_businesses_biz_idx on game.player_businesses (business_id);

create table if not exists game.districts (
  id int primary key,
  name text not null,
  description text not null,
  wealth bigint not null check (wealth > 0),
  difficulty int not null default 1,
  holder_id bigint references game.factions(id) on delete set null,
  contested_at timestamptz,
  last_tribute_at timestamptz
);
delete from game.districts;
insert into game.districts (id, name, description, wealth, difficulty) values
 (1,  'The Docks',        'Cranes, warehouses and boats that leave without lights.', 4000, 2),
 (2,  'Old Market',       'Stalls by day, empty crates and side deals after dark.',  3000, 1),
 (3,  'The Row',          'Tenements, narrow stairs and cheaper loyalties.',         2500, 1),
 (4,  'Midtown',          'Offices, lunch counters and fat envelopes.',              5000, 3),
 (5,  'Harbor Lights',    'Clubs along the water and too many witnesses.',           5500, 3),
 (6,  'Industrial Yard',  'Fences, night shifts and a lot of room to hide a truck.', 4500, 2),
 (7,  'University Hill',  'Quiet streets and houses with better locks.',             4800, 3),
 (8,  'City Center',      'Banks, hotels and pride. Expensive to hold.',             7000, 4),
 (9,  'The Flats',        'Low houses, long alleys, and room to disappear.',         3200, 2),
 (10, 'North Ridge',      'Gates, gardens and money that thinks it is safe.',        8000, 5);
create index if not exists districts_holder_idx on game.districts (holder_id);

create table if not exists game.bounties (
  id bigint generated always as identity primary key,
  placer_id bigint not null references game.players(id) on delete cascade,
  target_id bigint not null references game.players(id) on delete cascade,
  amount bigint not null check (amount >= 1000),
  created_at timestamptz not null default now(),
  collected_by bigint references game.players(id) on delete set null,
  collected_at timestamptz
);
create index if not exists bounties_target_open_idx on game.bounties (target_id) where collected_at is null;
create index if not exists bounties_placer_idx on game.bounties (placer_id);

create table if not exists game.swiss_cds (
  id bigint generated always as identity primary key,
  player_id bigint not null references game.players(id) on delete cascade,
  amount bigint not null check (amount >= 1000),
  interest_bps int not null,
  opened_at timestamptz not null default now(),
  matures_at timestamptz not null,
  collected boolean not null default false
);
create index if not exists swiss_player_idx on game.swiss_cds (player_id, collected);

create table if not exists game.raid_bosses (
  id int primary key,
  name text not null,
  description text not null,
  min_level int not null default 1,
  min_members int not null default 2,
  difficulty int not null default 1,
  chest_min bigint not null,
  chest_max bigint not null,
  energy_cost int not null default 20
);
delete from game.raid_bosses;
insert into game.raid_bosses (id, name, description, min_level, min_members, difficulty, chest_min, chest_max, energy_cost) values
 (1, 'Armored Courier',  'A moving lockbox and a two-man escort.',                 5,  2, 1,  8000,  16000, 15),
 (2, 'Night Counting House', 'A back-room cash desk after the blinds come down.', 10,  2, 2, 18000,  36000, 20),
 (3, 'Harbor Warehouse', 'A dock shed with a heavier door than it needs.',        15,  3, 3, 35000,  70000, 25),
 (4, 'Private Vault',    'A hill-house vault and people paid to keep it closed.', 22,  3, 4, 70000, 140000, 30);

create table if not exists game.raids (
  id bigint generated always as identity primary key,
  faction_id bigint not null references game.factions(id) on delete cascade,
  boss_id int not null references game.raid_bosses(id),
  leader_id bigint not null references game.players(id) on delete cascade,
  status text not null default 'open' check (status in ('open','won','failed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  chest bigint not null default 0,
  log jsonb not null default '[]'::jsonb
);
create index if not exists raids_faction_idx on game.raids (faction_id, status);

create table if not exists game.raid_members (
  raid_id bigint not null references game.raids(id) on delete cascade,
  player_id bigint not null references game.players(id) on delete cascade,
  role text not null check (role in ('breach','hack','combat')),
  primary key (raid_id, player_id)
);
create index if not exists raid_members_player_idx on game.raid_members (player_id);

-- ---------------------------------------------------------------------------
-- 9. Rename NPC thugs (keep ids so nothing else breaks)
-- ---------------------------------------------------------------------------
update game.players set username = 'Street_Punk',   level = 1,  cash = 200,   str = 3,    def = 3,    spd = 2,    dex = 2,    troops = 0,    hp = 100
 where is_npc and id = 1;
update game.players set username = 'Corner_Thug',   level = 3,  cash = 800,   str = 25,   def = 25,   spd = 20,   dex = 20,   troops = 6,    hp = 140
 where is_npc and id = 2;
update game.players set username = 'Dock_Brawler',  level = 8,  cash = 3000,  str = 120,  def = 110,  spd = 100,  dex = 100,  troops = 16,   hp = 240
 where is_npc and id = 3;
update game.players set username = 'Made_Hand',     level = 15, cash = 8000,  str = 450,  def = 400,  spd = 420,  dex = 380,  troops = 30,   hp = 380
 where is_npc and id = 4;
update game.players set username = 'Old_Capo',      level = 25, cash = 20000, str = 1500, def = 1400, spd = 1300, dex = 1300, troops = 50,   hp = 580
 where is_npc and id = 5;

-- ---------------------------------------------------------------------------
-- 10. Lock new tables the same way as the rest of the game schema
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'game' loop
    execute format('alter table game.%I enable row level security', t);
    execute format('revoke all on table game.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on all sequences in schema game from public, anon, authenticated;
