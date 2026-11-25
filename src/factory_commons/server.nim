## The game server: the Coworld game contract, the shift loop, the player
## protocol and the shutdown order.
##
## Forked from `coworld-ctf/src/ctf/server.nim` for the route/artifact/shutdown
## skeleton — hosted certification probes exactly these routes, in this order,
## BEFORE the player pods start (lantern, 2026-08-23) — with bullwhip's JSON
## player protocol in place of paintbot's binary one.
##
## Routes:
##   GET /healthz                  liveness, from process start until
##                                 `shutdownGraceSeconds` after the artifacts
##   GET /client/player?slot&token  the seat's HTML shell; it NEVER opens the
##                                 player socket
##   WS  /player?slot&token         the seat socket; a bad token is refused with
##                                 a close, never a hang
##   GET /client/global             the broadcast client, embedded and spliced
##   WS  /global                    live spectator: the sprite protocol plus the
##                                 chrome JSON on the same binary channel
##
## `factory_commons.player.v2`, all JSON text frames:
##   game -> player: welcome / state (every shift boundary and at the end) /
##                   observation (one decision per shift) / final
##   player -> game: {"type":"register","control":"external"}
##                   {"type":"action","shift":N,"action":{...}}
##   Published prompt policies retain their registration adapter:
##   player -> game: {"type":"prompt","prompt":"<= 4000 chars",
##                    "scripted":"steward|stripper|freerider|"}

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  bitworld/spriteprotocol,
  curly,
  mummy,
  mummy/routers,
  ./sim, ./scripted, ./llm, ./broadcast, ./global, ./replays, ./wire_constants

const
  BroadcastEveryTicks = 6
    ## The live spectator gets a frame every sixth tick. The static replay is
    ## the product; `/global` exists so certification's WebSocket ping is
    ## answered and a human can watch a hosted episode land.
  PlayBudgetFraction* = 0.6
    ## Share of the platform's episode timeout spent playing. The rest covers
    ## container start, player connects and writing the artifacts — the part
    ## that must never be the thing that runs out of time.

  GlobalPage = staticRead("../../client/replay_broadcast.html")
  ChromeCommonJs = staticRead("../../client/chrome_common.js")
  BroadcastCoreJs = staticRead("../../client/broadcast_core.js")
  ChromeCommonMarker = "<!-- CHROME_COMMON -->"
  BroadcastCoreMarker = "<!-- BROADCAST_CORE -->"

  PlayerPage = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Factory Commons — seat</title>
<style>
  html,body{margin:0;height:100%;background:#120d0a;color:#f2e8d8;
    font:14px/1.5 ui-monospace,Menlo,Consolas,monospace}
  main{max-width:44rem;margin:0 auto;padding:2rem}
  h1{font-size:1.1rem;letter-spacing:.14em;text-transform:uppercase;
    color:#e8a33d;margin:0 0 1rem}
  code{background:#1e1611;padding:.1rem .3rem;color:#ddc531}
  p{margin:.6rem 0}
</style></head><body><main>
<h1>Factory Commons — seat view</h1>
<p>Three cogs, one machine. The cycle press pays the whole room; the override
lever pays only you and breaks the machine forever.</p>
<p>A policy here <strong>is a prompt</strong>. This page is informational only:
it never opens the player socket. Decisions are made in the game container,
which asks every seat's prompt at each shift boundary as one parallel batch.</p>
<p>Field your own policy by reusing this image and setting
<code>PLAYER_PROMPT</code>, or play a baseline with
<code>PLAYER_SCRIPTED=steward|stripper|freerider</code>.</p>
<p>The spectator board is at <code>/client/global</code>; the replay is a static
wasm bundle, never a pod.</p>
</main></body></html>
"""

type
  GameState = object
    selection: PromptSelection
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    external: seq[bool]
    registered: seq[bool]
    disconnected: seq[bool]
    awaiting: seq[bool]
    actions: seq[JsonNode]
    rejected: seq[string]
    rejectedRaw: seq[string]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewerStates: Table[WebSocket, GlobalViewerState]
    started: bool
    finished: bool
    servingAfterEnd: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig

initLock(stateLock)

proc policyNames(gs: GameState): seq[string] =
  ## Seats play under anonymous cog aliases; the POLICY names ride alongside for
  ## the spectator views and `results.names` only. Both name spaces, never
  ## either.
  for player in gs.config.players:
    result.add(player.name)

proc hudModel(gs: GameState): HudModel =
  let
    sim = gs.sim
    band = sim.band()
  result.tick = max(0, sim.tick - 1)
  result.maxTick = sim.config.maxTicks()
  result.startTick = 0
  result.shift = sim.shift
  result.shifts = sim.config.shifts
  result.ticksPerShift = sim.config.ticksPerShift
  result.integrity = sim.machine.integrity
  result.cap = sim.machine.cap
  result.band = $band
  result.mode = modeText(sim.machine.mode)
  result.variant = sim.config.variantName()
  result.eitherOr = sim.config.eitherOr
  result.pink = sim.machine.pink
  result.blue = sim.machine.blue
  result.cooldown = sim.machine.cooldown
  result.pressYield = band.publicYield()
  result.stripYield = band.privateYield()
  result.pressLegal = sim.machine.cap >= sim.config.pressFloor and
    sim.machine.integrity >= sim.config.pressFloor and
    sim.config.modeAllows(sim.machine.mode, true)
  result.stripLegal = sim.machine.cap >= sim.config.pressFloor and
    sim.machine.integrity >= sim.config.stripFloor and
    sim.config.modeAllows(sim.machine.mode, false)
  result.presses = sim.machine.presses
  result.strips = sim.machine.strips
  result.repairs = sim.machine.repairs
  result.bananasMade = sim.machine.bananasMade
  result.bananasRotted = sim.machine.bananasRotted
  result.bananasSpoiled = sim.machine.bananasSpoiled
  result.scrappedBy = sim.machine.scrappedBy
  result.cubes = sim.cubes
  result.bananas = sim.bananas
  result.beltLen = sim.config.beltLen
  result.showLabels = sim.config.showPlayerLabels
  result.reason = sim.reason
  result.ending = sim.ending
  result.over = sim.done
  result.lastPressTick = -1
  result.lastStripTick = -1
  for cell in chuteCells():
    result.onChute += sim.bananasAt(cell[0], cell[1])
  let names = gs.policyNames()
  for seat in 0 ..< sim.cogs.len:
    let cog = sim.cogs[seat]
    result.seats.add(SeatHud(
      slot: seat,
      alias: Aliases[seat],
      policy: (if seat < names.len and names[seat].len > 0: names[seat]
               else: Aliases[seat]),
      color: SeatColors[seat],
      x: cog.x, y: cog.y, carrying: cog.carrying,
      score: sim.score(seat), eaten: cog.eaten, banked: cog.banked,
      presses: cog.presses, strips: cog.strips, repairs: cog.repairs,
      misfeeds: cog.misfeeds, fallbacks: cog.fallbacks,
      said: cog.said, job: $cog.order.job, cube: $cog.order.cube,
      source: $cog.order.source
    ))
  for row in sim.events:
    let kind = row{"k"}.getStr()
    if kind == "press":
      result.lastPressTick = row{"t"}.getInt()
    elif kind == "strip":
      result.lastStripTick = row{"t"}.getInt()

proc eventsSince(gs: GameState, fromTick: int): JsonNode =
  result = newJArray()
  for row in gs.sim.events:
    if row{"t"}.getInt(-1) > fromTick:
      result.add(row)

proc beatsJson(gs: GameState): JsonNode =
  result = newJArray()
  for row in gs.sim.beats:
    result.add(row)

var lastBroadcastTick = -1

proc broadcastLocked(gs: var GameState) =
  ## Callers hold stateLock. One packet per spectator, because each carries its
  ## own one-shot payloads (sprites, bands, the lead series, the beats).
  if gs.globalSockets.len == 0:
    lastBroadcastTick = max(0, gs.sim.tick - 1)
    return
  let
    model = gs.hudModel()
    events = gs.eventsSince(lastBroadcastTick)
    beats = gs.beatsJson()
  var sockets: seq[WebSocket]
  for socket in gs.globalSockets:
    sockets.add(socket)
  for socket in sockets:
    var current = gs.viewerStates.getOrDefault(socket, initGlobalViewerState())
    var nextState: GlobalViewerState
    let packet = buildViewerPacket(
      model, gs.config, current, nextState, events,
      playing = not gs.sim.done, speed = 1.0, looping = false,
      transportEnabled = false,
      leadSeries = gs.sim.series, beats = beats)
    gs.viewerStates[socket] = nextState
    for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
      socket.send(blobFromBytes(chunk), BinaryMessage)
  lastBroadcastTick = max(0, gs.sim.tick - 1)

proc sendPlayerStates(gs: var GameState) =
  var deadSlots: seq[int]
  for slot, socket in gs.playerSockets:
    if slot < gs.sim.cogs.len:
      try:
        socket.send($gs.sim.observationJson(slot))
      except CatchableError:
        deadSlots.add(slot)
  for slot in deadSlots:
    gs.playerSockets.del(slot)
    if gs.started and not gs.finished and slot >= 0 and slot < gs.disconnected.len:
      gs.disconnected[slot] = true

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honouring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  ## Shutdown, in this order: `final` to every player socket, the last global
  ## frame, a 500 ms flush, `results.json`, the replay, then `/healthz` and
  ## `/global` stay answering for `shutdownGraceSeconds` before `quit(0)`.
  ## Hosted certification pings the global websocket AFTER the player pods
  ## start, and a short episode would otherwise already be gone (lantern).
  var
    results: JsonNode
    replayData: string
    grace = 20
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    grace = state.config.shutdownGraceSeconds
    results = state.sim.resultsJson(state.policyNames())
    replayData = buildReplay(state.sim, state.policyNames(), results)

    ## The final frame goes to the PLAYER sockets, so it carries the aliases —
    ## `results.names` carries the policy names for the platform.
    var aliasNames = newJArray()
    for seat in 0 ..< state.sim.cogs.len:
      aliasNames.add(%Aliases[seat])
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "names": aliasNames,
      "shifts": results["shifts"],
      "reason": results["reason"],
      "ending": results["ending"]
    }
    ## The last observation, then the final frame: a seat sees the state it
    ## ended in before it is told the episode is over.
    state.sendPlayerStates()
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      try:
        socket.send($final)
      except CatchableError:
        discard
    state.broadcastLocked()

  sleep(500)
  log "writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  log "artifacts written (" & $replayData.len & " replay bytes); serving " &
    $grace & "s of shutdown grace"
  withLock stateLock:
    state.servingAfterEnd = true
  sleep(grace * 1000)
  log "episode complete, shutting down"
  quit(0)

proc failEpisode(
  runtimeConfig: RuntimeConfig,
  kind: FailureKind,
  code, message: string,
  seat = -1,
  rejectedAction = ""
) =
  ## Explicit failure lifecycle for unfinished/failed episodes (infrastructure,
  ## credential, transport, timeout, disconnect, or model-generated illegal/
  ## unparseable action). Never invents a forfeit, authoritative gameplay scores,
  ## or winners: writes Coworld's closed `GamePlayerFailure` JSON to
  ## `COGAME_PLAYER_FAILURE_URI` (when configured and a real seat failed),
  ## logs full game-specific diagnostics, notifies connected players, omits
  ## `results.json`, and exits non-zero.
  var
    failureJson: JsonNode
    diag = ""
  let failureKind =
    case kind
    of fkModelAction: "player_error"
    of fkInfra: "episode_inconclusive"
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    for s in 0 ..< state.awaiting.len:
      state.awaiting[s] = false
    var cleanMsg = cleanError(message)
    if cleanMsg.len == 0:
      cleanMsg = if code.len > 0: code else: "episode failed"
    if seat >= 0:
      failureJson = %*{
        "failed_policy_index": seat,
        "kind": failureKind,
        "message": cleanMsg
      }
    diag = "episode failed [" & $kind & "/" & code & " -> " & failureKind & "]"
    if seat >= 0:
      diag.add(" seat=" & $seat)
      if seat < state.sim.cogs.len:
        diag.add(" alias=" & Aliases[seat])
      let names = state.policyNames()
      if seat < names.len and names[seat].len > 0:
        diag.add(" policy=" & names[seat])
    diag.add(" shift=" & $(state.sim.shift + 1) &
      " shifts_completed=" & $state.sim.shift)
    if rejectedAction.len > 0:
      diag.add(" rejected_action=" & cleanError(rejectedAction))
    diag.add(": " & cleanMsg)

    let errorFrame = %*{
      "type": "error",
      "done": true,
      "failure_kind": $kind,
      "failure_code": code,
      "message": cleanMsg,
      "seat": seat
    }
    for _, socket in state.playerSockets:
      try:
        socket.send($errorFrame)
      except CatchableError:
        discard

  log diag
  sleep(200)
  let failureUri = getEnv("COGAME_PLAYER_FAILURE_URI").strip()
  if failureUri.len > 0 and not failureJson.isNil:
    try:
      writeArtifact(failureUri, $failureJson, "application/json",
        "COGAME_PLAYER_FAILURE_METHOD")
      log "player failure diagnostics written"
    except CatchableError as error:
      log "failed to write COGAME_PLAYER_FAILURE_URI: " & cleanError(error.msg)
  quit(1)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let
      config = state.config
      gameStart = epochTime()
      connectDeadline = gameStart + config.playerConnectTimeoutSeconds.float
    var allReady = false
    while epochTime() < connectDeadline:
      withLock stateLock:
        allReady = state.playerSockets.len >= config.numAgents
        if allReady:
          for seat in 0 ..< config.numAgents:
            if not state.playerSockets.hasKey(seat) or not state.registered[seat]:
              allReady = false
              break
      if allReady:
        break
      sleep(50)

    var
      missingSeat = -1
      connectedCount = 0
    withLock stateLock:
      state.started = true
      connectedCount = state.playerSockets.len
      allReady = connectedCount >= config.numAgents
      if allReady:
        for seat in 0 ..< config.numAgents:
          if not state.playerSockets.hasKey(seat) or not state.registered[seat]:
            allReady = false
            missingSeat = seat
            break
      else:
        for seat in 0 ..< config.numAgents:
          if not state.playerSockets.hasKey(seat) or not state.registered[seat]:
            missingSeat = seat
            break
      log "starting with " & $connectedCount & "/" &
        $config.numAgents & " seats connected"
      state.broadcastLocked()

    if not allReady:
      ## Missing or unregistered seats (whether zero or partial) are an
      ## infrastructure/startup failure, never an invented forfeit or silent
      ## scripted substitution.
      let msg =
        if connectedCount == 0:
          "no seats connected and registered within " &
          $config.playerConnectTimeoutSeconds & "s"
        else:
          "seat " & $missingSeat & " did not connect and register within " &
          $config.playerConnectTimeoutSeconds & "s"
      failEpisode(runtimeConfig, fkInfra, "seat_connect_timeout", msg,
        if connectedCount == 0: -1 else: missingSeat)
      return

    let client = newLlmClient(config)

    ## The platform kills an episode that outruns its timeout and keeps
    ## NOTHING, so play inside a fraction of it. The hosted dispatcher hands
    ## the timeout only to its own worker sidecar, never to the game container,
    ## so when the env is silent assume the configured platform default rather
    ## than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      log "episode timeout " & $timeoutSeconds.int & "s (" &
        (if hostedTimeout.len > 0: "from env" else: "assumed") &
        "); the last shift must START by " &
        $(timeoutSeconds * PlayBudgetFraction -
          (config.shiftBudgetSeconds() + config.settleBudgetSeconds()).float).int &
        "s so the episode SETTLES by " &
        $(timeoutSeconds * PlayBudgetFraction).int & "s"

    while true:
      var
        simCopy: Sim
        seats: seq[int]
        prompts: seq[string]
        scripted: seq[ScriptKind]
        external: seq[bool]
        disconnectedSeat = -1
        disconnectedShift = 0
        deadlineBeforeFirstShift = false
      withLock stateLock:
        if state.sim.done:
          break
        if not config.shiftFitsBeforeDeadline(epochTime(), playDeadline):
          if state.sim.shift == 0:
            deadlineBeforeFirstShift = true
          else:
            log "play deadline reached after " & $state.sim.shift & "/" &
              $config.shifts & " shifts (a shift needs " &
              $config.shiftBudgetSeconds() & "s and settling " &
              $config.settleBudgetSeconds() & "s); ending early"
            state.sim.endEarly()
            state.broadcastLocked()
            break
        if not deadlineBeforeFirstShift:
          for seat in 0 ..< state.sim.cogs.len:
            if state.disconnected[seat] or not state.playerSockets.hasKey(seat):
              disconnectedSeat = seat
              disconnectedShift = state.sim.shift + 1
              break
            seats.add(seat)
          if disconnectedSeat < 0:
            simCopy = state.sim
            prompts = state.prompts
            scripted = state.scripted
            external = state.external
            log "shift " & $(state.sim.shift + 1) & " of " & $config.shifts &
              " at " & $(epochTime() - gameStart).int & "s"

      if deadlineBeforeFirstShift:
        failEpisode(runtimeConfig, fkInfra, "play_deadline_before_first_shift",
          "play deadline reached before shift 1 could start")
        return

      if disconnectedSeat >= 0:
        failEpisode(runtimeConfig, fkInfra, "seat_disconnected",
          "seat " & $disconnectedSeat & " disconnected before shift " &
          $disconnectedShift, disconnectedSeat)
        return

      var hasExternal = false
      withLock stateLock:
        for seat in seats:
          state.rejected[seat] = ""
          state.rejectedRaw[seat] = ""
          if external[seat]:
            hasExternal = true
            state.awaiting[seat] = true
            state.actions[seat] = nil
            if state.playerSockets.hasKey(seat):
              try:
                state.playerSockets[seat].send($ %*{
                  "type": "observation",
                  "shift": simCopy.shift,
                  "observation": simCopy.observationJson(seat)
                })
              except CatchableError:
                state.playerSockets.del(seat)
                state.disconnected[seat] = true

      var managedSeats: seq[int]
      for seat in seats:
        if not external[seat]:
          managedSeats.add(seat)

      ## The slow part (LLM, ONE parallel batch for prompt seats) runs outside
      ## the lock on a snapshot; only this thread mutates the sim, so the
      ## snapshot cannot go stale.
      let batchStart = epochTime()
      var orders = newSeq[Order](seats.len)
      var
        hasDecisionError = false
        decisionKind = fkInfra
        decisionCode = ""
        decisionError = ""
        decisionSeat = -1
        decisionRejected = ""
      if managedSeats.len > 0:
        try:
          let managedOrders = client.decideAll(
            simCopy, managedSeats, prompts, scripted, state.selection)
          for i, seat in managedSeats:
            orders[seat] = managedOrders[i]
        except DecisionError as error:
          hasDecisionError = true
          decisionKind = error.kind
          decisionCode = error.code
          decisionError = cleanError(error.msg)
          decisionSeat = error.seat
          decisionRejected = error.rejectedAction
        except CatchableError as error:
          hasDecisionError = true
          decisionKind = fkInfra
          decisionCode = "llm_error"
          decisionError = cleanError(error.msg)
      let batchSeconds = epochTime() - batchStart

      if hasDecisionError:
        failEpisode(runtimeConfig, decisionKind, decisionCode, decisionError,
          decisionSeat, decisionRejected)
        return

      if hasExternal:
        let actionDeadline = epochTime() + config.llmTimeoutSeconds.float
        while epochTime() < actionDeadline:
          var waiting = false
          var failed = false
          withLock stateLock:
            for seat in seats:
              if state.disconnected[seat] or not state.playerSockets.hasKey(seat):
                failed = true
                break
              if external[seat]:
                if state.rejected[seat].len > 0:
                  failed = true
                  break
                if state.actions[seat].isNil:
                  waiting = true
          if failed or not waiting:
            break
          sleep(20)

      var
        hasExtFailure = false
        extKind = fkInfra
        extCode = ""
        extMessage = ""
        extSeat = -1
        extRejected = ""
      withLock stateLock:
        for index, seat in seats:
          if state.disconnected[seat] or not state.playerSockets.hasKey(seat):
            hasExtFailure = true
            extKind = fkInfra
            extCode = "seat_disconnected"
            extMessage = "seat " & $seat & " disconnected"
            extSeat = seat
            break
          if external[seat]:
            state.awaiting[seat] = false
            if state.rejected[seat].len > 0:
              hasExtFailure = true
              extKind = fkModelAction
              extCode = "external_action_rejected"
              extMessage = "seat " & $seat & " rejected action: " &
                state.rejected[seat]
              extSeat = seat
              extRejected = state.rejectedRaw[seat]
              break
            if state.actions[seat].isNil:
              hasExtFailure = true
              extKind = fkInfra
              extCode = "external_action_timeout"
              extMessage = "seat " & $seat & " missed action deadline"
              extSeat = seat
              break
            try:
              orders[index] = parseOrder(state.actions[seat])
              orders[index].source = osLlm
            except CatchableError as error:
              hasExtFailure = true
              extKind = fkModelAction
              extCode = "external_action_rejected"
              extMessage = "seat " & $seat & " invalid action: " &
                cleanError(error.msg)
              extSeat = seat
              extRejected = cleanError($state.actions[seat])
              break
        if not hasExtFailure:
          for index, seat in seats:
            var order = orders[index]
            order.latencyMs = int(batchSeconds * 1000.0)
            log "shift " & $(state.sim.shift + 1) & " " & Aliases[seat] &
              " -> " & $order.job & " " & $order.cube & " (" & $order.source &
              ")" & (if order.say.len > 0: " says \"" & order.say & "\"" else: "")
            state.sim.applyOrder(seat, order)
          ## The tick loop, with a spectator frame every few ticks.
          for _ in 0 ..< config.ticksPerShift:
            state.sim.stepTick()
            if state.sim.tick mod BroadcastEveryTicks == 0:
              state.broadcastLocked()
          state.sim.closeShift()
          state.sim.checkEnd(false)
          state.sendPlayerStates()
          state.broadcastLocked()
      if hasExtFailure:
        failEpisode(runtimeConfig, extKind, extCode, extMessage, extSeat,
          extRejected)
        return

      ## Floor the spacing between batch STARTS so the episode cannot exceed
      ## the Bedrock sidecar's 30 rpm per-episode ceiling.
      let pacing = config.turnPacingSleepMs(epochTime() - batchStart)
      if pacing > 0:
        sleep(pacing)

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    var page = spliceWireConstants(GlobalPage)
    page = page.replace(ChromeCommonMarker,
      "<script>" & ChromeCommonJs & "</script>")
    page = page.replace(BroadcastCoreMarker,
      "<script>" & BroadcastCoreJs & "</script>")
    request.respond(200, headers, page)

proc playerPageHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, PlayerPage)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let
      slotText = request.queryParams["slot"]
      token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      ## A bad token is refused outright — never a hang.
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      if slot < state.sim.connected.len:
        state.sim.connected[slot] = true
      log "seat " & $slot & " (" & Aliases[slot] & ") connected (" &
        $state.playerSockets.len & "/" & $state.config.numAgents & ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": ProtocolPlayer,
        "slot": slot,
        "name": Aliases[slot],
        "shifts": state.config.shifts,
        "ticksPerShift": state.config.ticksPerShift,
        "variant": state.config.variantName(),
        "numAgents": state.config.numAgents
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      state.viewerStates[websocket] = initGlobalViewerState()
      state.broadcastLocked()

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself, and the platform's certifier pings /global to check the game is
      ## alive — an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind == BinaryMessage:
        withLock stateLock:
          if websocket in state.globalSockets:
            var viewer = state.viewerStates.getOrDefault(
              websocket, initGlobalViewerState())
            viewer.applyGlobalViewerMessage(message.data)
            ## Live play has no transport: seeks and speed changes belong to
            ## the recorded replay, so they are accepted and ignored here.
            viewer.replaySeekTick = -1
            viewer.replayCommands = @[]
            state.viewerStates[websocket] = viewer
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload.kind != JObject:
          raise newException(FactoryError, "player frame must be a JSON object")
        let frameType = payload{"type"}
        if frameType.isNil or frameType.kind != JString:
          raise newException(FactoryError, "player frame missing string type")
        case frameType.getStr()
        of "register":
          let control = payload{"control"}
          if control.isNil or control.kind != JString or
              control.getStr() != "external":
            raise newException(FactoryError, "unknown player control")
          var ignored = false
          withLock stateLock:
            if state.started and state.registered[slot]:
              ignored = true
            else:
              state.external[slot] = true
              state.scripted[slot] = skNone
              state.registered[slot] = true
          if not ignored:
            log "seat " & $slot & " registered external action control"
        of "action":
          withLock stateLock:
            if state.external[slot] and state.awaiting[slot]:
              let shiftNode = payload{"shift"}
              if shiftNode.isNil or shiftNode.kind != JInt:
                raise newException(FactoryError, "action missing integer shift")
              if shiftNode.getInt() != state.sim.shift:
                raise newException(FactoryError,
                  "action shift " & $shiftNode.getInt() &
                  " does not match current shift " & $state.sim.shift)
              let action = payload{"action"}
              let order = parseOrder(action)
              if $order.job notin state.sim.legalJobs():
                raise newException(FactoryError,
                  "job is not legal: " & $order.job)
              state.actions[slot] = action
        of "prompt":
          let promptNode = payload{"prompt"}
          var prompt = ""
          if not promptNode.isNil and promptNode.kind != JNull:
            if promptNode.kind != JString:
              raise newException(FactoryError, "prompt must be a string")
            prompt = promptNode.getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          var kind = skNone
          if not node.isNil and node.kind != JNull:
            if node.kind != JString:
              raise newException(FactoryError, "scripted must be a string")
            let scriptedText = node.getStr().strip()
            if scriptedText.len > 0:
              kind = parseScriptKind(scriptedText)
              if kind == skNone:
                raise newException(FactoryError,
                  "unknown scripted baseline: " & cleanError(scriptedText))
          var ignored = false
          withLock stateLock:
            if state.started and state.registered[slot]:
              ignored = true
            else:
              state.prompts[slot] = prompt
              state.scripted[slot] = kind
              state.external[slot] = false
              state.registered[slot] = true
          if not ignored:
            log "seat " & $slot & " delivered a prompt (" & $prompt.len &
              " chars" & (if kind != skNone: ", scripted " & $kind else: "") & ")"
        else:
          raise newException(FactoryError,
            "unknown player frame type: " & cleanError(frameType.getStr()))
      except CatchableError as error:
        let reason = cleanError(error.msg)
        withLock stateLock:
          if state.external[slot] and state.awaiting[slot] and
              state.rejected[slot].len == 0:
            state.rejected[slot] = reason
            state.rejectedRaw[slot] = cleanError(message.data)
        log "rejected player frame from seat " & $slot & ": " & reason
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
            if state.started and not state.finished and
                slot >= 0 and slot < state.disconnected.len:
              state.disconnected[slot] = true
        state.globalSockets.excl(websocket)
        state.viewerStates.del(websocket)

proc buildRouter(): Router =
  ## Both `/client/` routes are registered BEFORE any catch-all asset route:
  ## the episode runner probes `/healthz`, `GET /client/player`, a bad-token
  ## player websocket and `GET /client/global` before starting player pods, and
  ## a 404 on any of them is a `game_contract_violation`.
  result.get("/healthz", healthzHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len < config.numAgents:
    raise newException(FactoryError,
      "config declares " & $config.numAgents & " seats but only " &
      $config.tokens.len & " tokens")
  state.selection = promptSelection(parseJson(runtimeConfig.config))
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.numAgents)
  state.scripted = newSeq[ScriptKind](config.numAgents)
  state.external = newSeq[bool](config.numAgents)
  state.registered = newSeq[bool](config.numAgents)
  state.disconnected = newSeq[bool](config.numAgents)
  state.awaiting = newSeq[bool](config.numAgents)
  state.actions = newSeq[JsonNode](config.numAgents)
  state.rejected = newSeq[string](config.numAgents)
  state.rejectedRaw = newSeq[string](config.numAgents)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter()
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  log "serving on " & runtimeConfig.host & ":" & $runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
