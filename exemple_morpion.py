"""
exemple_morpion.py
==================
Morpion à deux joueurs utilisant game_client.py.

Joueur 1 : python exemple_morpion.py
  -> affiche un ID de partie à transmettre au joueur 2

Joueur 2 : python exemple_morpion.py ABC123
  -> rejoint la partie

L'état de jeu transmis est simplement le plateau :
  [[0, 0, 0], [0, 1, 0], [0, 0, 2]]
  0 = vide, 1 = joueur 1 (X), 2 = joueur 2 (O)
"""

import sys
import json
from game_client import GameClient

SERVER = "wss://game-server-brisk-skylark-1315.fly.dev/ws?token=secret"

# Plateau 3x3 partagé localement
plateau = [[0] * 3 for _ in range(3)]
mon_numero = None   # 1 ou 2 (déterminé à l'arrivée du "start")
mon_tour = False


def afficher_plateau():
    symboles = {0: ".", 1: "X", 2: "O"}
    print()
    for ligne in plateau:
        print(" ".join(symboles[c] for c in ligne))
    print()


def verifier_victoire(p):
    """Retourne 1, 2 ou 0 (pas de vainqueur)."""
    for joueur in [1, 2]:
        # Lignes et colonnes
        for i in range(3):
            if all(p[i][j] == joueur for j in range(3)):
                return joueur
            if all(p[j][i] == joueur for j in range(3)):
                return joueur
        # Diagonales
        if all(p[i][i] == joueur for i in range(3)):
            return joueur
        if all(p[i][2 - i] == joueur for i in range(3)):
            return joueur
    return 0


def jouer(client: GameClient):
    """Demander un coup à l'utilisateur et l'envoyer."""
    afficher_plateau()
    while True:
        try:
            coup = input("Ton coup (ligne colonne, ex: 1 2) : ")
            l, c = map(int, coup.strip().split())
            if not (0 <= l <= 2 and 0 <= c <= 2):
                print("Coordonnées invalides (0-2).")
                continue
            if plateau[l][c] != 0:
                print("Case occupée.")
                continue
            plateau[l][c] = mon_numero
            break
        except (ValueError, IndexError):
            print("Format invalide.")
    client.move(plateau)
    afficher_plateau()
    vainqueur = verifier_victoire(plateau)
    if vainqueur:
        print(f"Tu as gagné !" if vainqueur == mon_numero else "Tu as perdu.")
        client.stop()


# --------------------------------------------------------------------------
# Callbacks GameClient
# --------------------------------------------------------------------------

def on_start(client: GameClient):
    global mon_numero, mon_tour
    print("\n=== La partie commence ! ===")
    # Par convention : le créateur (joueur 1) commence
    if client.game_id is not None:
        # Ce client a créé la partie -> joueur 1
        mon_numero = 1
        mon_tour = True
        print("Tu joues X (premier).")
    else:
        mon_numero = 2
        mon_tour = False
        print("Tu joues O (second). Attends le coup de l'adversaire.")
    if mon_tour:
        jouer(client)


def on_update(client: GameClient, state):
    global plateau, mon_tour
    # L'adversaire a joué : mettre à jour le plateau local
    plateau = state
    afficher_plateau()
    vainqueur = verifier_victoire(plateau)
    if vainqueur:
        print("L'adversaire a gagné." if vainqueur != mon_numero else "Tu as gagné !")
        client.stop()
        return
    mon_tour = True
    jouer(client)


def on_opponent_left(client: GameClient):
    print("\nL'adversaire a quitté la partie.")
    client.stop()


# --------------------------------------------------------------------------
# Point d'entrée
# --------------------------------------------------------------------------

def main():
    TOKEN = "motdepasse_classe"  # à remplacer par le token fourni

    client = GameClient(
            url=SERVER,
            token=TOKEN,
            on_start=on_start,
            on_update=on_update,
            on_opponent_left=on_opponent_left,
        )

    if len(sys.argv) == 1:
        # Créer une partie
        game_id = client.create()
        print(f"\nPartie créée. Transmets cet ID à ton adversaire : {game_id}")
        print("En attente du second joueur...\n")
    else:
        # Rejoindre une partie
        game_id = sys.argv[1].upper()
        print(f"\nRejoindre la partie {game_id}...")
        client.join(game_id)

    client.run()


if __name__ == "__main__":
    main()
