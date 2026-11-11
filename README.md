# Noir Syndicate

A text-based, persistent multiplayer underworld crime game in the style of classic browser games.
Play it at **https://iron-front-ww.vercel.app/** (recommended; this is the copy with HTTP security headers).
A GitHub Pages copy also stays up at **https://samarasecret.github.io/ww-game/**, but that host cannot set those headers.

You play in the fictional city of Grayhaven. The game is original work: original name, copy, and art, in a black-and-white noir style.

## Gameplay
- **Register** with a username and password, then climb the ranks from Runner through Underworld Legend and beyond. There is no ordinary level cap (a safety ceiling of 1,000,000 avoids overflow).
- **The Yard**: spend energy to raise Strength, Defense, Speed and Dexterity (diminishing returns). Every level-up also grants **5 stat points** you can assign to those four stats.
- **Crimes**: spend nerve on jobs from a pickpocket run to a night vault. Failure can wound you or land you in jail.
- **The Streets**: fight street thugs or other players (level 3+). Combat is resolved on the server as a round-by-round log. A win can collect any bounty on the target.
- **Specialization** (level 15, chosen once): **Enforcer**, **Hustler**, **Fixer** or **Ghost**, each with a passive edge and two path moves.
- **Crew**: every level-up grants **+2 free crew** (up to **300 free crew** in total). Everything beyond that is hired with dirty cash. The absolute maximum crew size is **1,000**. Outfit your crew with weapon crates. Other players only see a coarse class (Street Crew … Empire).
- **Cartels & turf**: found (for $10,000 dirty cash), join or leave a cartel. Hold Grayhaven districts, collect daily tribute into the cartel vault, and run multi-stage co-op jobs (breach, hack, combat) against raid targets. Payouts go to the vault.
- **Garage**: boost vehicles off the street, tune them, chop them for scrap, or export them through the docks.
- **Fronts**: buy businesses that slowly launder dirty cash into clean cash (48-hour catch-up cap).
- **Hospital & Jail**: wait out the timer or pay to leave early. You can also hit someone in the hospital or break someone out of jail.
- **Black Market**: buy, equip and sell personal weapons and armor. Every weapon, armor piece, crew crate, vehicle and front has an illustrated black-and-white image (with a stencil icon as a fallback if the image fails to load).
- **Bank**: deposit **clean** cash (1% fee). The teller will also launder dirty cash into clean for a steep cut. Swiss accounts hold clean cash for a term and pay yield if you wait.
- **Bounties, Directory, Leaderboards, Events and The Wire** (chat). Public profiles and wealth/stats/crew boards never show exact cash, bank, stats or inventory.
- **Admin panel** (shown only to the admin account after a normal login, enforced on the server):
  - Powers on the admin's own character: instant refill, instant release, set stats/level, grant dirty cash/crew/weapons/cars, Immortal mode, God strike, and a broadcast to every player's Events.
  - The admin is hidden from The Streets, the Directory and leaderboards and appears as **The Boss** to players.
  - Every admin action is written to an admin-only audit log.
  - Player management: player list, ban/unban, give/take dirty or clean cash, set a path, reset a player, global announcements, recent events.

Dirty cash is pocket money (spent on the street, stolen in fights). Clean cash is what you have laundered. The bank holds clean deposits only.

Energy regenerates +5 every 5 minutes (max 100), nerve +1 every 5 minutes (max 10), health +10% every 5 minutes.

## How it is built and hosted
- **Frontend**: plain HTML, CSS and JavaScript (no build step). The recommended public site is **https://iron-front-ww.vercel.app/**, hosted on **Vercel**, which enforces HTTP security headers (see `vercel.json` and [SECURITY.md](SECURITY.md)). A copy also remains on **GitHub Pages** at https://samarasecret.github.io/ww-game/. Prefer the Vercel link.
- **Backend**: **Supabase** (Postgres). All game rules live in SQL functions (`supabase/migrations/`).
- The browser talks only to named public RPCs. Game tables live in a private `game` schema, are not exposed through the API, and have Row Level Security on with no table privileges for `anon` or `authenticated`.
