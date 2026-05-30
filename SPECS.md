# Spécifications du serveur de jeu

## Vue d'ensemble

Serveur WebSocket générique pour jeux à deux joueurs en temps réel.
Le serveur est **agnostique au jeu** : il ne connaît pas les règles, ne valide pas les coups, et ne stocke l'état que de manière opaque. Toute la logique de jeu vit dans les clients.

- **Langage** : Gleam (cible Erlang/OTP)
- **Transport** : WebSocket sur HTTP/HTTPS
- **Format** : JSON
- **Déploiement** : fly.io (Paris, `cdg`)
- **URL** : `wss://<app>.fly.dev/ws?token=<TOKEN>`

---

## Architecture

```
Client A ──WS──┐
               ├── ws_handler (processus OTP par connexion)
Client B ──WS──┘        │
                         └── registry (acteur OTP global)
                                  │
                         Dict(game_id → {player1, player2})
```

### Composants

| Module | Rôle |
|---|---|
| `game_server` | Point d'entrée, routing HTTP, vérification du token |
| `ws_handler` | Un processus par connexion WebSocket, gère l'état local |
| `registry` | Acteur OTP global, table des parties en cours |
| `protocol` | Parsing et sérialisation des messages JSON |
| `game_server_ffi` | FFI Erlang : génération d'ID, sérialisation JSON opaque |

---

## Authentification

Toute connexion WebSocket doit inclure le token dans le query string :

```
wss://<host>/ws?token=<GAME_TOKEN>
```

- Le token est configuré via la variable d'environnement `GAME_TOKEN` au démarrage.
- Une connexion sans token ou avec un token incorrect reçoit une réponse HTTP `401` avant l'upgrade WebSocket.
- Le serveur refuse de démarrer si `GAME_TOKEN` est absent ou vide.

---

## Protocole WebSocket

Tous les messages sont des **trames texte JSON**.

### Messages client → serveur

#### Créer une partie

```json
{"type": "create"}
```

Crée une nouvelle partie. Le serveur génère un identifiant de 6 caractères (ex. `"ABC123"`) et répond avec `created`.

#### Rejoindre une partie

```json
{"type": "join", "game_id": "ABC123"}
```

Rejoint la partie identifiée par `game_id`. La partie doit exister et avoir une place libre.

#### Envoyer un coup

```json
{"type": "move", "state": <valeur JSON quelconque>}
```

Transmet l'état de jeu à l'adversaire. `state` peut être n'importe quelle valeur JSON valide (objet, tableau, nombre, etc.). Le serveur ne l'interprète pas.

### Messages serveur → client

#### Partie créée

```json
{"type": "created", "game_id": "ABC123"}
```

Envoyé en réponse à `create`. Le client doit transmettre `game_id` à son adversaire hors-bande.

#### Démarrage

```json
{"type": "start"}
```

Envoyé **aux deux joueurs** quand le second rejoint la partie. Indique que la partie peut commencer.

#### Mise à jour

```json
{"type": "update", "state": <valeur JSON>}
```

Envoyé à l'adversaire du joueur qui a fait un `move`. `state` est la valeur exacte transmise par l'autre joueur.

#### Adversaire parti

```json
{"type": "opponent_left"}
```

Envoyé quand l'adversaire se déconnecte (fermeture propre ou connexion morte détectée).

#### Erreur

```json
{"type": "error", "reason": "..."}
```

Raisons possibles :

| `reason` | Cause |
|---|---|
| `"game not found"` | `game_id` inexistant dans `join` |
| `"game full"` | La partie a déjà deux joueurs |
| `"not in a game"` | `move` envoyé avant d'avoir rejoint une partie |
| `"registry timeout"` | Le registry OTP n'a pas répondu en 1 s |
| `"JSON invalide : ..."` | Message JSON malformé |
| `"type inconnu : ..."` | Champ `type` non reconnu |

#### Keepalive ping (serveur → client)

```json
{"type": "ping"}
```

Envoyé par le serveur toutes les **30 secondes**. Le client **doit** répondre avec un `pong` (voir ci-dessous). Si aucun pong n'est reçu avant le tick suivant, la connexion est considérée morte et fermée côté serveur.

#### Keepalive pong (client → serveur)

```json
{"type": "pong"}
```

Réponse obligatoire au `ping` du serveur. Doit être envoyé dès réception du ping. Le `game_client.py` fourni le gère automatiquement.

---

## Cycle de vie d'une partie

```
Joueur 1                    Serveur                    Joueur 2
   │                           │                           │
   │──── create ──────────────►│                           │
   │◄─── created (game_id) ────│                           │
   │                           │◄───── join (game_id) ─────│
   │◄─── start ────────────────│─────── start ────────────►│
   │                           │                           │
   │──── move {state} ────────►│─────── update {state} ───►│
   │◄─── update {state} ───────│◄────── move {state} ──────│
   │           ...             │              ...           │
   │                           │                           │
   │  [fermeture connexion]    │                           │
   │                           │──── opponent_left ───────►│
```

- Une partie est identifiée par un **ID de 6 caractères** tiré aléatoirement dans l'alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (sans caractères ambigus).
- La partie est supprimée du registry dès qu'un joueur se déconnecte.
- Il n'y a pas de limite de durée ni de gestion des matchs nuls côté serveur.

---

## Détection de déconnexion

### Mécanisme principal : `on_close`

Contrairement à ce que la documentation de mist suggère, les variantes `mist.Closed` et `mist.Shutdown` du handler ne sont **jamais livrées** : mist convertit les messages internes via une fonction qui retourne `Error(Nil)` pour tout ce qui n'est pas Text/Binary/Custom, et appelle directement le callback `on_close` pour toute fermeture.

C'est donc `on_close` — et lui seul — qui envoie `Leave` au registry.

| Scénario | Mécanisme | Délai |
|---|---|---|
| Close frame WebSocket (fermeture propre) | `on_close` via mist | Immédiat |
| TCP FIN (processus client tué) | `on_close` via mist | Immédiat |
| TCP RST (crash réseau) | `on_close` via mist | Immédiat |
| Connexion zombie (proxy bufferise) | Ping sans pong → `mist.stop()` → `on_close` | ~60 s (2 × 30 s) |
| Inactivité longue (fly.io proxy) | Ping maintient la connexion active | Sans objet |

### Mécanisme secondaire : ping/pong applicatif

Pour les connexions zombies que le TCP ne signale pas immédiatement (proxy qui bufferise les écritures) :

```
Tick N   → envoie {"type":"ping"}, missed_pongs = 1
Tick N+1 → missed_pongs >= 1 et pas de pong reçu → mist.stop() → on_close → Leave

Pong reçu à tout moment → missed_pongs = 0
```

### Effet d'une déconnexion

Dans tous les cas, `on_close` déclenche :
1. `Leave` envoyé au registry
2. `opponent_left` envoyé à l'adversaire
3. Suppression de la partie du registry

---

## Endpoints HTTP

| Méthode | Path | Auth | Réponse |
|---|---|---|---|
| `GET` | `/health` | Non | `200 ok` — health check fly.io |
| `GET` | `/` | Non | `200` — aide textuelle sur le protocole |
| `GET` | `/ws?token=…` | Token | Upgrade WebSocket (ou `401`) |
| `GET` | `/status?token=…` | Token | `200` JSON — snapshot des parties en cours |
| Autres | `*` | — | `404` |

---

## Monitoring

### Logs en temps réel

Le registry émet des logs structurés pour chaque événement. En production :

```sh
fly logs
```

Format des événements :

| Événement | Log |
|---|---|
| Partie créée | `[CREATE] game=ABC123` |
| Second joueur rejoint, partie lancée | `[START] game=ABC123` |
| Tentative de join échouée | `[JOIN] game=ABC123 not_found` ou `full` |
| Coup transmis | `[MOVE] game=ABC123` |
| Joueur déconnecté | `[LEAVE] game=ABC123` |

### Snapshot `/status`

Retourne l'état courant de toutes les parties en mémoire. Protégé par le token.

```sh
curl "https://<app>.fly.dev/status?token=<GAME_TOKEN>"
```

Réponse :

```json
{
  "games": [
    {"game_id": "ABC123", "players": 2, "status": "playing"},
    {"game_id": "DEF456", "players": 1, "status": "waiting"}
  ],
  "total_games": 2,
  "total_players": 3
}
```

Champ `status` :

| Valeur | Signification |
|---|---|
| `"waiting"` | 1 joueur connecté, en attente du second |
| `"playing"` | 2 joueurs connectés, partie en cours |

---

## Limites et contraintes

- **Parties simultanées** : illimitées en théorie, bornées par la mémoire (256 MB sur fly.io).
- **Joueurs par partie** : exactement 2. Pas de spectateurs.
- **Taille des messages** : limitée par mist (pas de limite applicative configurée).
- **Persistance** : aucune. Le registry est en mémoire ; un redémarrage efface toutes les parties.
- **Scalabilité** : une seule instance (`min_machines_running = 1` recommandé). Plusieurs instances ne partageraient pas le registry.

---

## Variables d'environnement

| Variable | Obligatoire | Description |
|---|---|---|
| `GAME_TOKEN` | Oui | Token d'accès partagé avec les clients. Le serveur panique au démarrage si absent. |
