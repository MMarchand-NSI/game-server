// game_server.gleam
//
// Point d'entrée. Démarre :
//   1. Le registry OTP (état global des parties)
//   2. Le serveur HTTP/WebSocket mist sur 0.0.0.0:8000
//
// Protection par token : la variable d'environnement GAME_TOKEN doit être
// définie. Toute connexion WebSocket sans ?token=<valeur correcte> est rejetée
// avec un 401 avant même l'upgrade.
//
// Déploiement :
//   fly secrets set GAME_TOKEN=motdepasse_classe

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import logging
import mist
import registry
import ws_handler

@external(erlang, "game_server_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

pub fn main() {
  logging.configure()
  logging.set_level(logging.Info)

  // Lecture du token au démarrage — plante si absent, ce qui est voulu :
  // un serveur sans token configuré ne doit pas démarrer.
  let token = case get_env("GAME_TOKEN") {
    Ok(t) if t != "" -> t
    _ -> {
      logging.log(
        logging.Error,
        "Variable d'environnement GAME_TOKEN absente ou vide. Arrêt.",
      )
      panic as "GAME_TOKEN non configuré"
    }
  }

  let assert Ok(reg) = registry.start()
  logging.log(logging.Info, "Registry démarré")

  let assert Ok(_) =
    fn(req) {
      case request.path_segments(req) {
        ["ws"] -> {
          case check_token(req, token) {
            True ->
              mist.websocket(
                request: req,
                on_init: ws_handler.on_init(reg),
                on_close: ws_handler.on_close,
                handler: ws_handler.handler,
              )
            False ->
              response.new(401)
              |> response.set_header("content-type", "text/plain; charset=utf-8")
              |> response.set_body(
                mist.Bytes(bytes_tree.from_string("Token invalide ou manquant.")),
              )
          }
        }

        ["health"] ->
          response.new(200)
          |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))

        ["status"] -> {
          case check_token(req, token) {
            False ->
              response.new(401)
              |> response.set_body(
                mist.Bytes(bytes_tree.from_string("Token invalide.")),
              )
            True -> {
              let reply = process.new_subject()
              process.send(reg, registry.GetStatus(reply_to: reply))
              let body = case process.receive(reply, 500) {
                Error(_) -> "{\"error\":\"timeout\"}"
                Ok(games) -> {
                  let total_players =
                    list.fold(games, 0, fn(acc, g) { acc + g.players })
                  json.object([
                    #(
                      "games",
                      json.array(games, fn(g) {
                        json.object([
                          #("game_id", json.string(g.game_id)),
                          #("players", json.int(g.players)),
                          #(
                            "status",
                            json.string(case g.players {
                              1 -> "waiting"
                              _ -> "playing"
                            }),
                          ),
                        ])
                      }),
                    ),
                    #("total_games", json.int(list.length(games))),
                    #("total_players", json.int(total_players)),
                  ])
                  |> json.to_string
                }
              }
              response.new(200)
              |> response.set_header("content-type", "application/json")
              |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
            }
          }
        }

        [] ->
          response.new(200)
          |> response.set_header("content-type", "text/plain; charset=utf-8")
          |> response.set_body(mist.Bytes(bytes_tree.from_string(help_text())))

        _ ->
          response.new(404)
          |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    }
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(8000)
    |> mist.start

  logging.log(logging.Info, "Serveur sur 0.0.0.0:8000")
  process.sleep_forever()
}

// --------------------------------------------------------------------------
// Vérification du token dans le query string
// --------------------------------------------------------------------------

fn check_token(req: request.Request(mist.Connection), expected: String) -> Bool {
  case request.get_query(req) {
    Error(_) -> False
    Ok(params) ->
      case list.key_find(params, "token") {
        Ok(value) -> value == expected
        Error(_) -> False
      }
  }
}

// --------------------------------------------------------------------------

fn help_text() -> String {
  "Game Server - protocole WebSocket sur wss://<host>/ws?token=<TOKEN>

Messages client -> serveur (JSON) :
  {\"type\": \"create\"}
  {\"type\": \"join\", \"game_id\": \"XXXXXX\"}
  {\"type\": \"move\", \"state\": <valeur JSON quelconque>}

Messages serveur -> client (JSON) :
  {\"type\": \"created\", \"game_id\": \"XXXXXX\"}
  {\"type\": \"start\"}
  {\"type\": \"update\", \"state\": <valeur JSON>}
  {\"type\": \"opponent_left\"}
  {\"type\": \"error\", \"reason\": \"...\"}
"
}
