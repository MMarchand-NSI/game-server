// ws_handler.gleam
//
// Gestion d'une connexion WebSocket cliente.
// Le parsing JSON est entièrement délégué à protocol.gleam.

import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import mist
import protocol
import registry.{
  type RegistryMsg, type WsOutgoing, Create, Created, GarbageCollect, Join,
  JoinFull, JoinNotFound, JoinOk, Leave, Move, OpponentLeft, ServerError, Start,
  Update,
}

const ping_interval_ms = 30_000

// Délai avant suppression d'une partie sans second joueur (5 minutes)
const waiting_timeout_ms = 300_000

// Nombre maximum de messages par fenêtre d'une seconde
const rate_limit_max = 10

const rate_window_ms = 1_000

// --------------------------------------------------------------------------
// État d'une connexion WebSocket
// --------------------------------------------------------------------------

pub type ConnState {
  ConnState(
    game_id: Option(String),
    self: process.Subject(WsOutgoing),
    registry: process.Subject(RegistryMsg),
    tick: process.Subject(ConnMsg),
    missed_pongs: Int,
    rate_count: Int,
  )
}

pub type ConnMsg {
  FromRegistry(WsOutgoing)
  Tick
  RateReset
}

// --------------------------------------------------------------------------
// on_init
// --------------------------------------------------------------------------

pub fn on_init(
  registry: process.Subject(RegistryMsg),
) -> fn(mist.WebsocketConnection) ->
  #(ConnState, Option(process.Selector(ConnMsg))) {
  fn(_conn) {
    let self = process.new_subject()
    let tick = process.new_subject()
    process.send_after(tick, ping_interval_ms, Tick)
    process.send_after(tick, rate_window_ms, RateReset)
    let state =
      ConnState(
        game_id: None,
        self: self,
        registry: registry,
        tick: tick,
        missed_pongs: 0,
        rate_count: 0,
      )
    let selector =
      process.new_selector()
      |> process.select_map(self, FromRegistry)
      |> process.select(tick)
    #(state, Some(selector))
  }
}

// --------------------------------------------------------------------------
// Gestionnaire principal
// --------------------------------------------------------------------------

pub fn handler(
  state: ConnState,
  msg: mist.WebsocketMessage(ConnMsg),
  conn: mist.WebsocketConnection,
) -> mist.Next(ConnState, ConnMsg) {
  case msg {
    mist.Text(raw) -> {
      case state.rate_count >= rate_limit_max {
        True -> {
          let _ =
            mist.send_text_frame(
              conn,
              protocol.serialize_error("rate limit exceeded"),
            )
          mist.continue(ConnState(..state, rate_count: state.rate_count + 1))
        }
        False ->
          handle_client_message(
            ConnState(..state, rate_count: state.rate_count + 1),
            conn,
            raw,
          )
      }
    }
    mist.Custom(FromRegistry(outgoing)) ->
      handle_registry_message(state, conn, outgoing)
    mist.Custom(Tick) -> handle_tick(state, conn)
    mist.Custom(RateReset) -> {
      process.send_after(state.tick, rate_window_ms, RateReset)
      mist.continue(ConnState(..state, rate_count: 0))
    }
    mist.Closed | mist.Shutdown -> mist.continue(state)
    mist.Binary(_) -> mist.continue(state)
  }
}

// --------------------------------------------------------------------------
// Appelé par mist quand la connexion se ferme (TCP FIN/RST, close frame,
// ou mist.stop()). C'est ici, et seulement ici, que Leave est envoyé.
// mist.Closed/Shutdown dans le handler ne sont jamais livrés par mist.
// --------------------------------------------------------------------------

pub fn on_close(state: ConnState) -> Nil {
  case state.game_id {
    Some(id) -> process.send(state.registry, Leave(id, state.self))
    None -> Nil
  }
}

// --------------------------------------------------------------------------
// Keepalive : vérifie que la connexion est vivante, replanifie le prochain tick
// --------------------------------------------------------------------------

fn handle_tick(
  state: ConnState,
  conn: mist.WebsocketConnection,
) -> mist.Next(ConnState, ConnMsg) {
  case state.missed_pongs >= 1 {
    True -> {
      // Aucun pong reçu depuis le dernier ping : connexion morte.
      // on_close() se chargera d'envoyer Leave au registry.
      mist.stop()
    }
    False -> {
      let _ = mist.send_text_frame(conn, "{\"type\":\"ping\"}")
      process.send_after(state.tick, ping_interval_ms, Tick)
      mist.continue(ConnState(..state, missed_pongs: state.missed_pongs + 1))
    }
  }
}

// --------------------------------------------------------------------------
// Traitement d'un message client (parsing robuste via protocol.gleam)
// --------------------------------------------------------------------------

fn handle_client_message(
  state: ConnState,
  conn: mist.WebsocketConnection,
  raw: String,
) -> mist.Next(ConnState, ConnMsg) {
  case protocol.parse_client_msg(raw) {
    Error(reason) -> {
      let _ = mist.send_text_frame(conn, protocol.serialize_error(reason))
      mist.continue(state)
    }

    Ok(protocol.MsgCreate) -> {
      // Si le joueur était déjà dans une partie en attente, la libérer
      case state.game_id {
        Some(old_id) -> process.send(state.registry, Leave(old_id, state.self))
        None -> Nil
      }
      let reply_subj = process.new_subject()
      process.send(state.registry, Create(reply_to: reply_subj, ws: state.self))
      case process.receive(reply_subj, 1000) {
        Ok(Created(game_id)) -> {
          let _ =
            mist.send_text_frame(conn, protocol.serialize_created(game_id))
          process.send_after(
            state.registry,
            waiting_timeout_ms,
            GarbageCollect(game_id),
          )
          mist.continue(ConnState(..state, game_id: Some(game_id)))
        }
        Error(_) -> {
          let _ =
            mist.send_text_frame(
              conn,
              protocol.serialize_error("registry timeout"),
            )
          mist.continue(state)
        }
      }
    }

    Ok(protocol.MsgJoin(game_id)) -> {
      let reply_subj = process.new_subject()
      process.send(
        state.registry,
        Join(game_id: game_id, reply_to: reply_subj, ws: state.self),
      )
      case process.receive(reply_subj, 1000) {
        Ok(JoinOk) ->
          mist.continue(ConnState(..state, game_id: Some(game_id)))
        Ok(JoinNotFound) -> {
          let _ =
            mist.send_text_frame(
              conn,
              protocol.serialize_error("game not found"),
            )
          mist.continue(state)
        }
        Ok(JoinFull) -> {
          let _ =
            mist.send_text_frame(conn, protocol.serialize_error("game full"))
          mist.continue(state)
        }
        Error(_) -> {
          let _ =
            mist.send_text_frame(
              conn,
              protocol.serialize_error("registry timeout"),
            )
          mist.continue(state)
        }
      }
    }

    Ok(protocol.MsgPong) ->
      mist.continue(ConnState(..state, missed_pongs: 0))

    Ok(protocol.MsgMove(game_state)) -> {
      case state.game_id {
        None -> {
          let _ =
            mist.send_text_frame(
              conn,
              protocol.serialize_error("not in a game"),
            )
          mist.continue(state)
        }
        Some(id) -> {
          process.send(state.registry, Move(id, state.self, game_state))
          mist.continue(state)
        }
      }
    }
  }
}

// --------------------------------------------------------------------------
// Traitement des messages du registry (push serveur -> client)
// --------------------------------------------------------------------------

fn handle_registry_message(
  state: ConnState,
  conn: mist.WebsocketConnection,
  outgoing: WsOutgoing,
) -> mist.Next(ConnState, ConnMsg) {
  let payload = case outgoing {
    Start -> protocol.serialize_start()
    Update(game_state) -> protocol.serialize_update(game_state)
    OpponentLeft -> protocol.serialize_opponent_left()
    ServerError(reason) -> protocol.serialize_error(reason)
  }
  let _ = mist.send_text_frame(conn, payload)
  mist.continue(state)
}
