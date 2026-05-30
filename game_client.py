"""
game_client.py
==============
Client WebSocket générique pour le serveur de jeu.

Les élèves n'écrivent pas ce fichier : ils l'importent.
Dépendance : websockets  (pip install websockets)

Usage type :
    from game_client import GameClient

    def on_start(client):
        print("La partie commence !")

    def on_update(client, state):
        print("L'adversaire a joué :", state)
        client.move({"plateau": [[1, 0], [0, 2]]})

    client = GameClient(
        url="wss://game-server.fly.dev/ws",
        token="motdepasse_classe",
        on_start=on_start,
        on_update=on_update,
    )

    game_id = client.create()
    print("Transmets cet ID à ton adversaire :", game_id)
    client.run()
"""

import json
import threading
import asyncio
import websockets
from urllib.parse import urlencode


class GameClient:
    """
    Client synchrone pour le serveur de jeu WebSocket.

    Paramètres
    ----------
    url : str
        URL WebSocket de base du serveur (ex. "wss://game-server.fly.dev/ws").
        Ne pas inclure le token ici.
    token : str
        Token d'accès fourni par l'enseignant.
    on_start : callable(client)
        Appelé quand la partie démarre.
    on_update : callable(client, state)
        Appelé quand l'adversaire envoie un état de jeu.
        `state` est la valeur JSON décodée (dict, list, int, etc.).
    on_opponent_left : callable(client), optionnel
    on_error : callable(client, reason), optionnel
    """

    def __init__(
        self,
        url: str,
        token: str,
        on_start,
        on_update,
        on_opponent_left=None,
        on_error=None,
    ):
        # Construire l'URL avec le token dans le query string
        separator = "&" if "?" in url else "?"
        self._url = url + separator + urlencode({"token": token})

        self._on_start = on_start
        self._on_update = on_update
        self._on_opponent_left = on_opponent_left or (lambda c: None)
        self._on_error = on_error or (lambda c, r: print(f"[Erreur serveur] {r}"))

        self._ws = None
        self._loop = None
        self._game_id = None
        self._ready = threading.Event()
        self._thread = None
        self._connect_error = None

    # ------------------------------------------------------------------
    # API publique
    # ------------------------------------------------------------------

    def create(self) -> str:
        """
        Crée une nouvelle partie.
        Bloque jusqu'à réception de l'ID.
        Lève une exception si le token est refusé.
        """
        id_event = threading.Event()
        result = {}

        def on_created(game_id):
            result["game_id"] = game_id
            id_event.set()

        self._pending_create = on_created
        self._start_loop()
        self._check_connect_error()
        self._send_sync({"type": "create"})
        id_event.wait(timeout=10)
        return result.get("game_id", "")

    def join(self, game_id: str) -> None:
        """Rejoint une partie existante via son ID."""
        self._start_loop()
        self._check_connect_error()
        self._send_sync({"type": "join", "game_id": game_id})

    def move(self, state) -> None:
        """
        Envoie un état de jeu à l'adversaire.
        `state` peut être n'importe quelle valeur sérialisable en JSON.
        """
        self._send_sync({"type": "move", "state": state})

    def stop(self) -> None:
        """Ferme la connexion WebSocket et arrête le client."""
        if self._ws and self._loop:
            asyncio.run_coroutine_threadsafe(self._ws.close(), self._loop)

    def run(self) -> None:
        """Bloque jusqu'à la fin de la partie. Répond à Ctrl+C."""
        if self._thread:
            try:
                while self._thread.is_alive():
                    self._thread.join(timeout=0.5)
            except KeyboardInterrupt:
                self.stop()

    # ------------------------------------------------------------------
    # Boucle asyncio interne
    # ------------------------------------------------------------------

    def _start_loop(self):
        if self._thread is not None:
            self._ready.wait(timeout=5)
            return

        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()
        self._ready.wait(timeout=5)

    def _run_loop(self):
        asyncio.set_event_loop(self._loop)
        self._loop.run_until_complete(self._connect_and_listen())

    async def _connect_and_listen(self):
        try:
            async with websockets.connect(self._url) as ws:
                self._ws = ws
                self._ready.set()
                async for raw in ws:
                    await asyncio.to_thread(self._dispatch, raw)
        except websockets.exceptions.InvalidStatus as e:
            # Le serveur a répondu 401 : token incorrect
            if e.response.status_code == 401:
                self._connect_error = (
                    f"Token refusé (HTTP 401). "
                    f"Vérifiez que le token est correct."
                )
            else:
                self._connect_error = f"Connexion refusée : HTTP {e.response.status_code}"
            self._ready.set()
        except Exception as e:
            self._connect_error = f"Erreur de connexion : {e}"
            self._ready.set()

    def _check_connect_error(self):
        if self._connect_error:
            raise ConnectionError(self._connect_error)

    def _dispatch(self, raw: str):
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            return

        msg_type = msg.get("type")

        if msg_type == "created":
            self._game_id = msg.get("game_id")
            if hasattr(self, "_pending_create"):
                self._pending_create(self._game_id)

        elif msg_type == "start":
            self._on_start(self)

        elif msg_type == "update":
            self._on_update(self, msg.get("state"))

        elif msg_type == "opponent_left":
            self._on_opponent_left(self)

        elif msg_type == "error":
            self._on_error(self, msg.get("reason", "unknown"))

    def _send_sync(self, payload: dict):
        raw = json.dumps(payload)
        future = asyncio.run_coroutine_threadsafe(
            self._ws.send(raw), self._loop
        )
        future.result(timeout=5)

    @property
    def game_id(self) -> str | None:
        return self._game_id
