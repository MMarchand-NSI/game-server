# Déploiement sur fly.io

## Prérequis

- [flyctl](https://fly.io/docs/hands-on/install-flyctl/) installé et connecté (`fly auth login`)
- Un compte fly.io (gratuit pour commencer)
- Docker installé localement (pour tester l'image avant déploiement)

## Première mise en production

### 1. Créer l'application

```sh
fly launch --no-deploy
```

Fly détecte le `fly.toml` existant et propose de l'utiliser. Choisissez un nom d'application unique — il détermine l'URL publique : `https://<nom>.fly.dev`.

Mettez à jour le `fly.toml` avec ce nom :

```toml
app = "votre-nom-unique"
```

### 2. Configurer le secret

Le serveur refuse de démarrer sans `GAME_TOKEN`. Définissez-le une fois :

```sh
fly secrets set GAME_TOKEN=votre_mot_de_passe_secret
```

Le secret est chiffré et injecté comme variable d'environnement au démarrage du conteneur. Il n'apparaît jamais dans les logs ni dans le Dockerfile.

### 3. Déployer

```sh
fly deploy
```

Fly construit l'image Docker en deux étapes (build Gleam → image Erlang minimale), la pousse dans son registry, puis démarre la machine.

### 4. Vérifier

```sh
fly status                               # état de la machine
curl https://votre-nom.fly.dev/health    # doit retourner "ok"
```

---

## Mises à jour

Chaque modification du code se déploie avec :

```sh
fly deploy
```

Fly effectue un déploiement sans interruption : la nouvelle version démarre avant que l'ancienne soit arrêtée.

---

## Tester le WebSocket en production

Avec [websocat](https://github.com/vi/websocat) :

```sh
websocat "wss://votre-nom.fly.dev/ws?token=votre_mot_de_passe_secret"
```

Puis envoyez des messages JSON :

```json
{"type": "create"}
```

Réponse attendue :

```json
{"type":"created","game_id":"ABC123"}
```

---

## Changer le token

```sh
fly secrets set GAME_TOKEN=nouveau_mot_de_passe
```

La machine redémarre automatiquement avec le nouveau secret.

---

## Logs

```sh
fly logs          # logs en temps réel
fly logs --past   # logs récents
```

---

## Configuration fly.toml

| Paramètre | Valeur actuelle | Notes |
|---|---|---|
| `primary_region` | `cdg` | Paris — changez selon vos joueurs |
| `auto_stop_machines` | `stop` | La machine s'arrête sans trafic |
| `min_machines_running` | `0` | Passe à `1` pour éviter le cold start |
| `memory` | `256mb` | Suffisant pour quelques parties simultanées |

### Désactiver le cold start

Si les parties sont coupées au redémarrage de la machine, forcez une instance toujours active :

```toml
[http_service]
  auto_stop_machines = "stop"
  min_machines_running = 1
```

```sh
fly deploy
```

Cela consomme du crédit fly.io en continu (environ 2 $/mois pour un `shared-cpu-1x`).

---

## Supprimer l'application

```sh
fly apps destroy votre-nom
```
