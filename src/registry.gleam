// registry.gleam
//
// Actor OTP global qui maintient la table des parties en cours.
// Chaque partie (Game) stocke les Subject des deux connexions WebSocket
// afin de pouvoir leur transmettre des messages serveur -> client.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import logging

// --------------------------------------------------------------------------
// Types publics
// --------------------------------------------------------------------------

/// Message que le registry peut recevoir.
pub type RegistryMsg {
  /// Un joueur crée une nouvelle partie. Le serveur génère un ID et répond.
  Create(reply_to: Subject(CreateReply), ws: Subject(WsOutgoing))

  /// Un joueur rejoint une partie existante.
  Join(
    game_id: String,
    reply_to: Subject(JoinReply),
    ws: Subject(WsOutgoing),
  )

  /// Un joueur transmet un état de jeu à son adversaire.
  Move(game_id: String, from_ws: Subject(WsOutgoing), state: String)

  /// Une connexion WebSocket se ferme.
  Leave(game_id: String, ws: Subject(WsOutgoing))

  /// Demande un snapshot de l'état courant (pour /status).
  GetStatus(reply_to: Subject(List(GameInfo)))

  /// Supprime une partie en attente si personne n'a rejoint dans le délai imparti.
  GarbageCollect(game_id: String)
}

pub type GameInfo {
  GameInfo(game_id: String, players: Int)
}

/// Réponse à une demande de création.
pub type CreateReply {
  Created(game_id: String)
}

/// Réponse à une demande de rejoindre.
pub type JoinReply {
  JoinOk
  JoinNotFound
  JoinFull
}

/// Messages que le registry envoie vers une connexion WebSocket.
pub type WsOutgoing {
  /// La partie vient de commencer (deux joueurs connectés).
  Start
  /// L'adversaire a joué ; voici son état de jeu.
  Update(state: String)
  /// L'adversaire a quitté la partie.
  OpponentLeft
  /// Erreur générique.
  ServerError(reason: String)
}

// --------------------------------------------------------------------------
// État interne du registry
// --------------------------------------------------------------------------

type Game {
  Game(
    // Joueur 1 (créateur)
    player1: Subject(WsOutgoing),
    // Joueur 2 (optionnel tant que la partie n'a pas démarré)
    player2: Option(Subject(WsOutgoing)),
  )
}

type State =
  Dict(String, Game)

// --------------------------------------------------------------------------
// Démarrage
// --------------------------------------------------------------------------

pub fn start() -> Result(Subject(RegistryMsg), actor.StartError) {
  actor.new(dict.new())
  |> actor.on_message(handle_message)
  |> actor.start
  |> fn(r) {
    case r {
      Ok(started) -> Ok(started.data)
      Error(e) -> Error(e)
    }
  }
}

// --------------------------------------------------------------------------
// Boucle de messages
// --------------------------------------------------------------------------

fn handle_message(
  state: State,
  msg: RegistryMsg,
) -> actor.Next(State, RegistryMsg) {
  case msg {
    Create(reply_to, ws) -> {
      let game_id = generate_id()
      let game = Game(player1: ws, player2: None)
      let new_state = dict.insert(state, game_id, game)
      process.send(reply_to, Created(game_id))
      logging.log(logging.Info, "[CREATE] game=" <> game_id)
      actor.continue(new_state)
    }

    Join(game_id, reply_to, ws) -> {
      case dict.get(state, game_id) {
        Error(_) -> {
          process.send(reply_to, JoinNotFound)
          logging.log(logging.Warning, "[JOIN] game=" <> game_id <> " not_found")
          actor.continue(state)
        }
        Ok(Game(_, Some(_))) -> {
          process.send(reply_to, JoinFull)
          logging.log(logging.Warning, "[JOIN] game=" <> game_id <> " full")
          actor.continue(state)
        }
        Ok(Game(player1, None)) -> {
          let updated = Game(player1: player1, player2: Some(ws))
          let new_state = dict.insert(state, game_id, updated)
          process.send(reply_to, JoinOk)
          process.send(player1, Start)
          process.send(ws, Start)
          logging.log(logging.Info, "[START] game=" <> game_id)
          actor.continue(new_state)
        }
      }
    }

    Move(game_id, from_ws, game_state) -> {
      case dict.get(state, game_id) {
        Error(_) -> actor.continue(state)
        Ok(Game(player1, Some(player2))) -> {
          case from_ws == player1 {
            True -> process.send(player2, Update(game_state))
            False -> process.send(player1, Update(game_state))
          }
          logging.log(logging.Info, "[MOVE] game=" <> game_id)
          actor.continue(state)
        }
        Ok(Game(_, None)) -> actor.continue(state)
      }
    }

    Leave(game_id, ws) -> {
      case dict.get(state, game_id) {
        Error(_) -> actor.continue(state)
        Ok(Game(player1, Some(player2))) -> {
          let opponent = case ws == player1 {
            True -> player2
            False -> player1
          }
          process.send(opponent, OpponentLeft)
          let new_state = dict.delete(state, game_id)
          logging.log(logging.Info, "[LEAVE] game=" <> game_id)
          actor.continue(new_state)
        }
        Ok(Game(_, None)) -> {
          let new_state = dict.delete(state, game_id)
          logging.log(logging.Info, "[LEAVE] game=" <> game_id <> " (solo)")
          actor.continue(new_state)
        }
      }
    }

    GarbageCollect(game_id) -> {
      case dict.get(state, game_id) {
        Ok(Game(player1, None)) -> {
          process.send(player1, ServerError("no opponent joined in time"))
          let new_state = dict.delete(state, game_id)
          logging.log(logging.Info, "[TIMEOUT] game=" <> game_id)
          actor.continue(new_state)
        }
        // Partie déjà démarrée ou supprimée : ignorer
        _ -> actor.continue(state)
      }
    }

    GetStatus(reply_to) -> {
      let games =
        state
        |> dict.to_list
        |> list.map(fn(entry) {
          let #(game_id, game) = entry
          let players = case game.player2 {
            Some(_) -> 2
            None -> 1
          }
          GameInfo(game_id: game_id, players: players)
        })
      process.send(reply_to, games)
      logging.log(
        logging.Debug,
        "[STATUS] games=" <> int.to_string(list.length(games)),
      )
      actor.continue(state)
    }
  }
}

// --------------------------------------------------------------------------
// Génération d'ID de partie (6 caractères alphanumériques)
// --------------------------------------------------------------------------

@external(erlang, "game_server_ffi", "generate_id")
pub fn generate_id() -> String
