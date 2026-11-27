LakoAutoRole 1.0.0 - World of Warcraft: Forever

INSTALL
Close the game, extract this ZIP, and copy the LakoAutoRole folder into the
Interface\AddOns folder of the WoW Forever installation you play.
The result should be Interface\AddOns\LakoAutoRole\LakoAutoRole.toc.
Launch the game and enable LakoAutoRole in the AddOns list.

RULES
Thick Hide (at least one point) AND Primal Bite -> Tank
Shifting Power -> DPS
Moonkin Form -> DPS
Wild Growth -> Healer

These are checks of learned talents in your ACTIVE specialization, not your
current shapeshift form. If an unusual hybrid build matches several rules,
the order above is the priority order. No matching rule leaves your current
role unchanged. Other classes are ignored.

Updates happen on login/reload, entering the world, joining or changing a
group, role polls, and talent or specialization changes. Pending talent edits
are ignored until applied or discarded. Changes during combat wait until
combat ends. Your detected role is applied when you are in a party or raid.
This addon sets the group role only, not Dungeon Finder queue selections.

No setup, dependencies, or permanent polling loop is needed. Only the
enabled/disabled preference is saved, separately for each character.

COMMANDS
/lar             Display detected talents and role status
/lar check       Recheck and apply your role
/lar off         Disable automatic roles
/lar on          Enable automatic roles (default)

If another addon repeatedly resets your role, turn off its automatic role
selection. LakoAutoRole corrects occasional overrides but limits repeated
attempts to avoid a role-changing loop.

VALIDATION
The Lua code and simulated talent/group events have been tested locally.
An in-game Forever test is still needed. If detection fails, run /lar and
send the displayed talent points and status, plus any Lua error.

API REFERENCES
Forever UI source, build 1.60.1.71037:
https://github.com/Gethe/wow-ui-source/tree/forever
SpecializationInfoDocumentation.lua, SharedTraitsDocumentation.lua,
UnitRoleDocumentation.lua, and Camelot/ClassTalents UI.
Spell identifiers checked against the Wowhead Forever spell database:
16929, 407995, 1322605, 24858, 408120.
