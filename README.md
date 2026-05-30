# Serveur de jeu générique — Gleam / fly.io

Serveur WebSocket permettant à deux joueurs de s'échanger un état de jeu
arbitraire. Les élèves écrivent uniquement le client Python.

## Protection par token

L'accès est restreint par un token dans le query string :

    wss://<host>/ws?token=<TOKEN>

Le token est stocké dans les secrets fly.io, jamais dans le code :

    fly secrets set GAME_TOKEN=motdepasse_classe

Le serveur refuse toute connexion sans token valide (HTTP 401).
Pour changer le token en cours d'année : `fly secrets set GAME_TOKEN=nouveau`.

## Architecture

```
Joueur 1 (Python)          Gleam / BEAM               Joueur 2 (Python)
  game_client.py  <--WS-->  mist + OTP actors  <--WS-->  game_client.py
```

Un actor OTP (Registry) maintient la table des parties en cours.
Chaque connexion WebSocket est un processus BEAM léger.

## Protocole JSON

### Client -> serveur

| Message | Description |
|---|---|
| `{"type": "create"}` | Créer une partie |
| `{"type": "join", "game_id": "XXXXXX"}` | Rejoindre une partie |
| `{"type": "move", "state": <JSON>}` | Envoyer un état de jeu |

### Serveur -> client

| Message | Description |
|---|---|
| `{"type": "created", "game_id": "XXXXXX"}` | Confirmation de création |
| `{"type": "start"}` | Partie démarrée |
| `{"type": "update", "state": <JSON>}` | État envoyé par l'adversaire |
| `{"type": "opponent_left"}` | L'adversaire s'est déconnecté |
| `{"type": "error", "reason": "..."}` | Erreur |

L'état (`state`) est opaque : le serveur le transmet tel quel.

## Déploiement sur fly.io

```sh
fly auth login
fly launch                                  # choisir un nom, région cdg
fly secrets set GAME_TOKEN=motdepasse_classe
fly deploy
fly logs                                    # logs en direct
```

Pour changer le token :

```sh
fly secrets set GAME_TOKEN=nouveau_token
fly deploy
```

## Utilisation côté élèves

```sh
pip install websockets
```

```python
from game_client import GameClient

def on_start(client):
    print("C'est parti !")
    client.move({"plateau": [[0]*3 for _ in range(3)]})

def on_update(client, state):
    print("État reçu :", state)
    # ... logique de jeu ...
    client.move(nouvel_etat)

client = GameClient(
    url="wss://<nom-app>.fly.dev/ws",
    token="motdepasse_classe",        # token fourni par l'enseignant
    on_start=on_start,
    on_update=on_update,
)

# Joueur 1 :
game_id = client.create()
print("ID à transmettre :", game_id)

# Joueur 2 (autre terminal) :
# client.join("XXXXXX")

client.run()
```

Voir `client/exemple_morpion.py` pour un exemple complet.

## Structure du projet

```
game_server/
  src/
    game_server.gleam       -- point d'entrée, vérification du token
    registry.gleam          -- actor OTP : table des parties
    ws_handler.gleam        -- gestion d'une connexion WebSocket
    protocol.gleam          -- parsing/sérialisation JSON robuste
    game_server_ffi.erl     -- génération d'ID + sérialisation Dynamic
  client/
    game_client.py          -- bibliothèque Python pour les élèves
    exemple_morpion.py      -- exemple d'utilisation
  Dockerfile
  fly.toml
  gleam.toml
```

## Développement local

```sh
export GAME_TOKEN=test
gleam run
# Serveur sur ws://localhost:8000/ws?token=test

python client/exemple_morpion.py         # terminal 1
python client/exemple_morpion.py XXXXXX  # terminal 2
```
