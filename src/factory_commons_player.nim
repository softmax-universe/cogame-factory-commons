## Factory Commons prompt and scripted player.
##
## `PLAYER_SCRIPTED=steward|stripper|freerider` registers the seat as a built-in
## baseline instead. The game plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <factory-commons-image> --name my-factory-commons \
##     --run /bin/factory-commons-player \
##     --secret-env PLAYER_PROMPT="<your strategy>" --secret-env USE_BEDROCK=true

import
  std/[json, options, os, strutils],
  whisky,
  factory_commons/scripted as fcScripted

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  var scripted = getEnv("PLAYER_SCRIPTED").strip().toLowerAscii()
  if scripted.len > 0:
    if fcScripted.parseScriptKind(scripted) == fcScripted.skNone:
      quit("PLAYER_SCRIPTED must be one of steward, stripper, freerider; got: " & scripted, 1)
    prompt = ""
  elif prompt.len == 0:
    ## When neither PLAYER_PROMPT nor PLAYER_SCRIPTED is set (for example the
    ## default certification player), explicitly register as the steward
    ## baseline rather than relying on a server-side fallback.
    scripted = "steward"

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "factory-commons player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "factory-commons player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## The receive loop is wrapped in `try/except CatchableError` and exits 0 on a
  ## closed or truncated socket. whisky's `receiveMessage` RAISES on a close
  ## frame or a truncated read (only a timeout returns `none`), and the game's
  ## `quit(0)` can outrun its own flushed `final` frame — so without this the
  ## player exits 1 on a race that passes one dispatch and fails the next
  ## (raid 0.1.3 -> 0.1.4, 2026-08-23).
  var running = true
  while running:
    var received: Option[Message]
    try:
      received = socket.receiveMessage()
    except CatchableError as error:
      echo "factory-commons player: socket closed (", error.msg,
        "); exiting cleanly"
      break
    if received.isNone:
      echo "factory-commons player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    let payload = parseJson(message.data)
    try:
      case payload{"type"}.getStr()
      of "welcome":
        echo "factory-commons player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
          " (variant ", payload{"variant"}.getStr(), ", ",
          payload{"shifts"}.getInt(), " shifts)"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "state":
        ## Informational: the seat does not decide here. Log one compact line so
        ## a hosted player log shows the episode progressing.
        let machine = payload{"machine"}
        echo "factory-commons player: shift ", payload{"shift"}.getInt(),
          "/", payload{"shifts"}.getInt(),
          " integrity ", machine{"integrity"}.getInt(),
          " cap ", machine{"cap"}.getInt(),
          " band ", machine{"band"}.getStr(),
          " score ", payload{"you"}{"score"}.getInt()
      of "final":
        echo "factory-commons player: final scores ", payload{"scores"},
          " reason ", payload{"reason"}.getStr(),
          " ending ", payload{"ending"}.getStr()
        running = false
      else:
        discard
    except CatchableError as error:
      echo "factory-commons player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
