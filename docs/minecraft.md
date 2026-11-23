# Minecraft

A private Minecraft server for a handful of players (up to 10), for the
**Bedrock** edition: the one on the Nintendo Switch, phones and tablets, Xbox,
PlayStation and Windows. It runs the official Bedrock Dedicated Server in the
`itzg/minecraft-bedrock-server` image, limited to 1.5 GB of memory.

## Enable it

On the host that should run it (one host only: the world lives in its data
folder and is not pushed to the others):

```
# host file: add minecraft to services=, optionally:
#   minecraft_name="blunderer.org"   minecraft_gamemode=survival
#   minecraft_difficulty=easy        minecraft_max_players=10
sudo srv deploy minecraft     # the first start downloads the server: a few minutes
```

Open **TCP 19132** (NetherNet signaling), **UDP 19140-19155** (NetherNet
WebRTC gameplay), and **UDP 19132-19133** (legacy RakNet) in the hosting
provider's firewall, if it has one.

## Accounts: who may play

Bedrock servers have no password. Instead every player signs in with a
**Microsoft account** (the game asks for one before any online play; on the
Switch, playing online also needs Nintendo Switch Online), and the server
only lets in the accounts on its **allow list**:

```
sudo box minecraft allow "KidOne"     # the account's gamertag, as in its Xbox profile
sudo box minecraft deny "KidOne"      # remove (then: box minecraft cmd kick "KidOne")
sudo box minecraft list               # who may join (and who has joined at least once)
```

Creating the accounts happens on Microsoft's side: a free account per child,
ideally as a child account in a Microsoft family group, where you approve
multiplayer and friends. Then add each gamertag with `box minecraft allow`.
Anyone else gets "You are not invited to this server".

Other commands:

```
sudo box minecraft op "Parent"        # operator: game rules, teleport, give items
sudo box minecraft deop "Parent"
sudo box minecraft cmd say Dinner time!    # any server command
sudo box minecraft cmd time set day
```

## Joining from a Nintendo Switch

The Switch version only lists Microsoft's featured servers and has no "Add
server" button. Two ways around it, both through BedrockConnect, a free
server list for consoles:

1. **BedrockConnect app** (simplest, nothing to change on the Switch): on a
   phone on the same Wi-Fi as the Switch, add a server with the address
   `orion.blunderer.org` (the host running minecraft), port `19132`. The
   Switch then shows it as a LAN game in the Friends tab; the app has to
   stay open until the game has joined.
2. **DNS** on the Switch (System Settings, Internet, the Wi-Fi network, DNS
   settings: manual, primary DNS: a BedrockConnect server listed on its
   site). Selecting any featured server then opens a list where you can add
   `orion.blunderer.org`, port `19132`, once; it is remembered.

Phones, tablets, Windows and Xbox can add the server directly: Play,
Servers, Add Server, address `orion.blunderer.org`, port `19132`.

## Versions

Consoles update the game automatically, and only join a server of the same
version. The server updates itself each time it starts (`VERSION=LATEST`),
so after a game update: `sudo srv restart minecraft`, or wait for the next
deploy. `srv deploy minecraft` also takes the newest image.

## Data and backups

Everything is in `<data>/minecraft/`: the world (`worlds/`), the settings
and `allowlist.json`. The local daily backup (`backup/diff-backup.sh`) keeps
copies like the rest of the data folder; the nightly push to the other hosts
skips it (`backup_exclude`), so a second host running minecraft keeps its own
world.

Logs: `journalctl -t minecraft` (joins, leaves, the answers to
`box minecraft` commands).
