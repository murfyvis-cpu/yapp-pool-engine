# Yapp — 8-ball pool engine (Luau)

Two server modules from the billiards minigame in **Yapp**, a Roblox game I own and
script (Roblox: murfyzinho). This is an excerpt of the game's source: the match service,
the table configuration and the client renderer are not included.

## `PoolPhysics.luau` — the table simulation

- Each `Step(dt)` is split into substeps of about 1/180 s (at most `MaxSubsteps` of
  them), which keeps fast contacts stable.
- Friction switches between sliding and rolling by the contact's slip speed, blending in
  between, and the ball's spin converges towards rolling.
- Ball–ball contacts: positional correction (slop plus a correction percent), a
  restitution impulse, tangential friction capped at a fraction of that impulse, and
  spin transfer through solid-sphere inertia (2/5·m·r²).
- Cushions are bounded segments with their own restitution, friction and spin
  influence; they are ignored right next to a pocket so balls can drop.
- Pockets capture inside their radius; sleep thresholds stop residual motion.
- `ApplyCueStrike` turns an impulse into velocity and an off-centre hit into spin.
- Each step returns its collisions (for sounds and effects) and the balls it pocketed.

## `PoolTurnResolver.luau` — the 8-ball rules

- Transport-free: it never touches a RemoteEvent, a Part or the Workspace. It reads the
  settled world, updates the match state and returns an outcome (foul, shoot again,
  game over, winner, re-spotted balls, sounds) for the caller to broadcast.
- Fouls: scratching, striking the wrong group first, and a stroke that pots nothing
  and reaches no rail after contact.
- Open table, then solids/stripes assigned by the first legal stroke that pots balls
  of only one group.
- The 8-ball wins only when the shooter's group was cleared before the stroke (one
  helper answers that for both the foul check and the win check). Potted on the break,
  it goes back on the foot spot, or on the nearest free point along the long string.
- After a foul the opponent gets ball in hand; a scratched cue ball is put back on the
  table.

## See it running

Yapp is private for now, so the system can be seen in the Yapp case study video (it
includes the billiards): https://murfy.me/en?projeto=interface-lab → **View videos**.

## How it fits in the game

On the server, `PoolMatch` (not included) builds a `PoolPhysics` world from the table
configuration, runs each shot and hands the settled world to `PoolTurnResolver`; the
clients replay the recorded trajectory.
