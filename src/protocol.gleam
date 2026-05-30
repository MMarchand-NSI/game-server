// protocol.gleam
//
// Parsing et sérialisation des messages du protocole.
//
// Utilise gleam_json v3 + gleam/dynamic/decode pour un parsing robuste :
// aucune extraction de chaîne manuelle, tous les cas d'erreur sont couverts.
//
// L'état de jeu ("state") est opaque pour le serveur : il est reçu comme
// fragment JSON brut (string) et retransmis tel quel, sans décodage.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/json

// --------------------------------------------------------------------------
// Types représentant les messages entrants (client -> serveur)
// --------------------------------------------------------------------------

pub type ClientMsg {
  MsgCreate
  MsgJoin(game_id: String)
  MsgMove(state: String)
  MsgPong
}

// --------------------------------------------------------------------------
// Parsing d'un message client
// --------------------------------------------------------------------------

/// Parse un message JSON brut venant du client.
/// Retourne une erreur descriptive si le JSON est invalide ou le type inconnu.
pub fn parse_client_msg(raw: String) -> Result(ClientMsg, String) {
  // Étape 1 : extraire le champ "type" (toujours une string)
  let type_decoder = decode.field("type", decode.string, decode.success)

  case json.parse(from: raw, using: type_decoder) {
    Error(e) -> Error("JSON invalide : " <> describe_json_error(e))
    Ok(msg_type) ->
      case msg_type {
        "create" -> Ok(MsgCreate)
        "join" -> parse_join(raw)
        "move" -> parse_move(raw)
        "pong" -> Ok(MsgPong)
        other -> Error("type inconnu : " <> other)
      }
  }
}

// -- Parsing de "join" -------------------------------------------------------

fn parse_join(raw: String) -> Result(ClientMsg, String) {
  let decoder = decode.field("game_id", decode.string, decode.success)
  case json.parse(from: raw, using: decoder) {
    Ok(game_id) -> Ok(MsgJoin(game_id))
    Error(_) -> Error("join : champ 'game_id' manquant ou invalide")
  }
}

// -- Parsing de "move" -------------------------------------------------------
//
// Le champ "state" est opaque : n'importe quelle valeur JSON valide est
// acceptée. On la valide (le JSON global doit être parsable) puis on
// extrait le fragment brut correspondant à "state".

fn parse_move(raw: String) -> Result(ClientMsg, String) {
  // Vérifier que le JSON est valide et contient "state"
  let presence_decoder =
    decode.field("state", decode.dynamic, fn(_) { decode.success(Nil) })

  case json.parse(from: raw, using: presence_decoder) {
    Error(_) -> Error("move : champ 'state' manquant ou JSON invalide")
    Ok(_) -> {
      // Extraire le fragment JSON brut de "state"
      // On utilise la FFI Erlang pour obtenir la valeur Dynamic puis
      // la re-sérialiser proprement.
      case extract_state_json(raw) {
        Ok(state_json) -> Ok(MsgMove(state_json))
        Error(reason) -> Error("move : " <> reason)
      }
    }
  }
}

// --------------------------------------------------------------------------
// Extraction du fragment JSON brut pour "state"
//
// Stratégie : parser tout l'objet, récupérer "state" comme Dynamic,
// puis le re-sérialiser via la FFI Erlang en JSON.
// Cela garantit que `state` est toujours du JSON valide et correctement
// échappé, quelle que soit sa structure.
// --------------------------------------------------------------------------

fn extract_state_json(raw: String) -> Result(String, String) {
  let dyn_decoder = decode.field("state", decode.dynamic, decode.success)
  case json.parse(from: raw, using: dyn_decoder) {
    Error(_) -> Error("impossible d'extraire 'state'")
    Ok(dyn_value) -> {
      case dynamic_to_json_string(dyn_value) {
        Ok(s) -> Ok(s)
        Error(_) -> Error("impossible de re-sérialiser 'state'")
      }
    }
  }
}

// FFI : convertit une valeur Dynamic Erlang (issue du parsing JSON)
// en sa représentation JSON string.
@external(erlang, "game_server_ffi", "dynamic_to_json")
fn dynamic_to_json_string(value: dynamic.Dynamic) -> Result(String, Nil)

// --------------------------------------------------------------------------
// Sérialisation des messages sortants (serveur -> client)
// --------------------------------------------------------------------------

pub fn serialize_created(game_id: String) -> String {
  json.object([#("type", json.string("created")), #("game_id", json.string(game_id))])
  |> json.to_string
}

pub fn serialize_start() -> String {
  json.object([#("type", json.string("start"))])
  |> json.to_string
}

pub fn serialize_update(state_json: String) -> String {
  // `state_json` est déjà du JSON valide : on l'insère via preprocessed_array
  // dans un objet. On passe par la FFI pour insérer du JSON brut sans
  // double-encodage.
  "{\"type\":\"update\",\"state\":" <> state_json <> "}"
}

pub fn serialize_opponent_left() -> String {
  json.object([#("type", json.string("opponent_left"))])
  |> json.to_string
}

pub fn serialize_error(reason: String) -> String {
  json.object([
    #("type", json.string("error")),
    #("reason", json.string(reason)),
  ])
  |> json.to_string
}

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

fn describe_json_error(e: json.DecodeError) -> String {
  case e {
    json.UnexpectedEndOfInput -> "fin de flux inattendue"
    json.UnexpectedByte(b) -> "octet inattendu : " <> b
    json.UnexpectedSequence(s) -> "séquence inattendue : " <> s
    json.UnableToDecode(_) -> "structure inattendue"
  }
}
