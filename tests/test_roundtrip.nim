## Public host + player round-trip tests against the real `factory-commons`
## server binary and `factory-commons-player` binary.
##
## Verifies:
##   1. Native model player (no PLAYER_SCRIPTED) with bare JSON reply completes,
##      executes the model-produced action, and writes scored results + replay.
##   2. Native model player with Markdown-fenced JSON reply completes and
##      executes the model-produced action.
##   3. Invalid/ambiguous model reply fails non-zero with model_invalid_action
##      diagnostics, rejected_action recorded, and NO numeric results.json.
##   4. Provider failure (HTTP 500) fails non-zero with infra diagnostics and
##      NO numeric results.json.
##   5. Missing LLM credentials on native model player fails non-zero with
##      infra/llm_missing_credentials diagnostics and NO numeric results.json.
##   6. Purely scripted offline certification seats complete with exit 0 and
##      scored results + replay without any LLM credentials.

import std/[json, net, os, osproc, streams, strtabs, strutils, times]

var checks = 0

template check(condition: untyped, message: string) =
  inc checks
  if not (condition):
    echo "FAIL: ", message
    quit(1)

proc repoRoot(): string =
  for candidate in [".", "..", currentSourcePath().parentDir() / ".."]:
    if fileExists(candidate / "coworld_manifest_template.json"):
      return absolutePath(candidate)
  ""

proc findFreePort(): int =
  var sock = newSocket()
  defer: sock.close()
  sock.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = sock.getLocalAddr()
  int(port)

proc compileBinary(root, srcRel, outPath: string) =
  let cmd = "nim c --hints:off --path:src -o:" & quoteShell(outPath) & " " &
    quoteShell(root / srcRel)
  let (output, code) = execCmdEx(cmd, workingDir = root)
  if code != 0:
    echo "FAIL: failed to compile ", srcRel, ":\n", output
    quit(1)

const StubServerScript = """
import http.server, json, sys

status = int(sys.argv[1])
body = sys.argv[2].encode("utf-8")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 0:
            self.rfile.read(length)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
"""

proc startStubSidecar(status: int, body: string): tuple[procObj: Process, port: int] =
  let p = startProcess(
    "python3",
    args = ["-u", "-c", StubServerScript, $status, body],
    options = {poUsePath}
  )
  let line = p.outputStream().readLine().strip()
  result = (p, parseInt(line))

proc anthropicTextBody(text: string): string =
  $ %*{"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}

proc cleanEnv(extra: openArray[(string, string)]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k in ["COWORLD_LLM_ENDPOINT", "COWORLD_LLM_MODEL", "ANTHROPIC_API_KEY",
             "ANTHROPIC_API_KEY_URI", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
             "AWS_BEARER_TOKEN_BEDROCK", "PLAYER_PROMPT", "PLAYER_SCRIPTED",
             "COWORLD_PLAYER_WS_URL", "COGAME_CONFIG_URI", "COGAME_RESULTS_URI",
             "COGAME_SAVE_REPLAY_URI", "COGAME_PLAYER_FAILURE_URI"]:
      continue
    result[k] = v
  for (k, v) in extra:
    result[k] = v

type
  EpisodeOutcome = object
    gameExit: int
    playerExits: seq[int]
    resultsExists: bool
    results: JsonNode
    replayExists: bool
    replay: JsonNode
    failureExists: bool
    failure: JsonNode
    gameLog: string

proc runEpisode(
  gameBin, playerBin, workDir: string,
  sidecarEndpoint: string,
  seatScripted: array[3, string]
): EpisodeOutcome =
  createDir(workDir)
  let
    port = findFreePort()
    configPath = workDir / "config.json"
    resultsPath = workDir / "results.json"
    replayPath = workDir / "replay.json"
    failurePath = workDir / "player_failure.json"

  let configJson = %*{
    "num_agents": 3,
    "seed": 11,
    "shifts": 1,
    "ticksPerShift": 10,
    "eitherOr": false,
    "minTurnSeconds": 0,
    "shutdownGraceSeconds": 0,
    "playerConnectTimeoutSeconds": 10,
    "tokens": ["tok-0", "tok-1", "tok-2"],
    "players": [
      {"name": "Bolt"},
      {"name": "Cotter"},
      {"name": "Ratchet"}
    ]
  }
  writeFile(configPath, $configJson)

  var gameEnvPairs = @[
    ("COGAME_HOST", "127.0.0.1"),
    ("COGAME_PORT", $port),
    ("COGAME_CONFIG_URI", "file://" & configPath),
    ("COGAME_RESULTS_URI", "file://" & resultsPath),
    ("COGAME_SAVE_REPLAY_URI", "file://" & replayPath),
    ("COGAME_PLAYER_FAILURE_URI", "file://" & failurePath)
  ]
  if sidecarEndpoint.len > 0:
    gameEnvPairs.add(("COWORLD_LLM_ENDPOINT", sidecarEndpoint))
    gameEnvPairs.add(("COWORLD_LLM_MODEL", "test-model"))

  let gameProc = startProcess(
    gameBin,
    env = cleanEnv(gameEnvPairs),
    options = {poStdErrToStdOut}
  )

  # Wait briefly for game HTTP/WS listener to bind.
  let waitDeadline = epochTime() + 5.0
  while epochTime() < waitDeadline:
    try:
      var probe = newSocket()
      probe.connect("127.0.0.1", Port(port), timeout = 100)
      probe.close()
      break
    except CatchableError:
      sleep(50)

  var playerProcs: seq[Process]
  for slot in 0 .. 2:
    var pEnv = @[
      ("COWORLD_PLAYER_WS_URL",
        "ws://127.0.0.1:" & $port & "/player?slot=" & $slot & "&token=tok-" & $slot)
    ]
    if seatScripted[slot].len > 0:
      pEnv.add(("PLAYER_SCRIPTED", seatScripted[slot]))
    playerProcs.add(startProcess(
      playerBin,
      env = cleanEnv(pEnv),
      options = {poStdErrToStdOut}
    ))

  result.gameExit = gameProc.waitForExit(timeout = 15_000)
  if gameProc.running():
    gameProc.terminate()
    result.gameExit = gameProc.waitForExit(timeout = 2_000)
  result.gameLog = gameProc.outputStream().readAll()
  gameProc.close()

  for p in playerProcs:
    var code = p.waitForExit(timeout = 5_000)
    if p.running():
      p.terminate()
      code = p.waitForExit(timeout = 2_000)
    result.playerExits.add(code)
    p.close()

  result.resultsExists = fileExists(resultsPath)
  if result.resultsExists:
    result.results = parseJson(readFile(resultsPath))
  result.replayExists = fileExists(replayPath)
  if result.replayExists:
    result.replay = parseJson(readFile(replayPath))
  result.failureExists = fileExists(failurePath)
  if result.failureExists:
    result.failure = parseJson(readFile(failurePath))

proc main() =
  let root = repoRoot()
  check root.len > 0, "repo root findable"

  let tmpBase = getTempDir() / ("fc-roundtrip-" & $getCurrentProcessId())
  createDir(tmpBase)
  defer:
    try: removeDir(tmpBase) except CatchableError: discard

  let
    gameBin = tmpBase / "factory-commons"
    playerBin = tmpBase / "factory-commons-player"
  compileBinary(root, "src/factory_commons.nim", gameBin)
  compileBinary(root, "src/factory_commons_player.nim", playerBin)

  block bareJsonModelRoundTrip:
    let stub = startStubSidecar(200, anthropicTextBody(
      """{"job":"maintain","cube":"pink","say":"model-bare-json","notes":"ok"}"""))
    defer:
      stub.procObj.terminate()
      discard stub.procObj.waitForExit(timeout = 2_000)
      stub.procObj.close()

    let outcome = runEpisode(
      gameBin, playerBin, tmpBase / "bare-json",
      "http://127.0.0.1:" & $stub.port,
      ["", "steward", "stripper"]
    )
    check outcome.gameExit == 0,
      "bare JSON round-trip exits 0; log:\n" & outcome.gameLog
    check outcome.resultsExists, "bare JSON writes results.json"
    check not outcome.failureExists, "bare JSON writes no player_failure.json"
    check outcome.results["reason"].getStr() == "complete",
      "bare JSON completes normally"
    check outcome.results["scores"].len == 3, "bare JSON writes 3 seat scores"
    check outcome.replayExists, "bare JSON writes replay.json"
    var sawModelOrder = false
    for ev in outcome.replay["events"]:
      if ev{"k"}.getStr() == "order" and ev{"seat"}.getInt(-1) == 0 and
          ev{"source"}.getStr() == "llm" and ev{"job"}.getStr() == "maintain" and
          ev{"say"}.getStr() == "model-bare-json":
        sawModelOrder = true
    check sawModelOrder,
      "bare JSON model-produced action executed on seat 0"

  block fencedJsonModelRoundTrip:
    let fenced = "```json\n" &
      """{"job":"eat","cube":"any","say":"model-fenced-json","notes":"fenced"}""" &
      "\n```"
    let stub = startStubSidecar(200, anthropicTextBody(fenced))
    defer:
      stub.procObj.terminate()
      discard stub.procObj.waitForExit(timeout = 2_000)
      stub.procObj.close()

    let outcome = runEpisode(
      gameBin, playerBin, tmpBase / "fenced-json",
      "http://127.0.0.1:" & $stub.port,
      ["", "steward", "stripper"]
    )
    check outcome.gameExit == 0,
      "fenced JSON round-trip exits 0; log:\n" & outcome.gameLog
    check outcome.resultsExists, "fenced JSON writes results.json"
    check not outcome.failureExists, "fenced JSON writes no player_failure.json"
    check outcome.results["reason"].getStr() == "complete",
      "fenced JSON completes normally"
    var sawModelOrder = false
    for ev in outcome.replay["events"]:
      if ev{"k"}.getStr() == "order" and ev{"seat"}.getInt(-1) == 0 and
          ev{"source"}.getStr() == "llm" and ev{"job"}.getStr() == "eat" and
          ev{"say"}.getStr() == "model-fenced-json":
        sawModelOrder = true
    check sawModelOrder,
      "fenced JSON model-produced action executed on seat 0"

  block invalidAmbiguousReplyFailsUnscored:
    let ambiguous = """Here is my move: {"job":"operate"} {"job":"idle"}"""
    let stub = startStubSidecar(200, anthropicTextBody(ambiguous))
    defer:
      stub.procObj.terminate()
      discard stub.procObj.waitForExit(timeout = 2_000)
      stub.procObj.close()

    let outcome = runEpisode(
      gameBin, playerBin, tmpBase / "invalid-reply",
      "http://127.0.0.1:" & $stub.port,
      ["", "steward", "stripper"]
    )
    check outcome.gameExit != 0,
      "invalid/ambiguous reply exits non-zero; log:\n" & outcome.gameLog
    check not outcome.resultsExists,
      "invalid/ambiguous reply writes NO results.json (no numeric results)"
    check outcome.failureExists,
      "invalid/ambiguous reply writes player_failure.json"
    check outcome.failure["failure_kind"].getStr() == "model_invalid_action",
      "invalid/ambiguous reply classified as model_invalid_action"
    check outcome.failure["failure_code"].getStr() == "llm_invalid_reply",
      "invalid/ambiguous reply records llm_invalid_reply code"
    check outcome.failure{"rejected_action"}.getStr().len > 0,
      "invalid/ambiguous reply records rejected_action diagnostics"
    check not outcome.failure.hasKey("scores") and not outcome.failure.hasKey("win"),
      "failure diagnostics carry no authoritative gameplay scores or winners"

  block providerFailure500FailsUnscored:
    let stub = startStubSidecar(500, """{"error":"upstream failure"}""")
    defer:
      stub.procObj.terminate()
      discard stub.procObj.waitForExit(timeout = 2_000)
      stub.procObj.close()

    let outcome = runEpisode(
      gameBin, playerBin, tmpBase / "provider-500",
      "http://127.0.0.1:" & $stub.port,
      ["", "steward", "stripper"]
    )
    check outcome.gameExit != 0,
      "provider 500 exits non-zero; log:\n" & outcome.gameLog
    check not outcome.resultsExists,
      "provider 500 writes NO results.json (no numeric results)"
    check outcome.failureExists,
      "provider 500 writes player_failure.json"
    check outcome.failure["failure_kind"].getStr() == "infra",
      "provider 500 classified as infra failure"
    check outcome.failure["failure_code"].getStr() == "llm_provider_error",
      "provider 500 records llm_provider_error code"
    check not outcome.failure.hasKey("scores") and not outcome.failure.hasKey("win"),
      "provider 500 failure carries no authoritative gameplay scores or winners"

  block missingCredentialsFailsUnscored:
    let outcome = runEpisode(
      gameBin, playerBin, tmpBase / "missing-creds",
      "",
      ["", "steward", "stripper"]
    )
    check outcome.gameExit != 0,
      "missing credentials on native model player exits non-zero; log:\n" &
      outcome.gameLog
    check not outcome.resultsExists,
      "missing credentials writes NO results.json (no numeric results)"
    check outcome.failureExists,
      "missing credentials writes player_failure.json"
    check outcome.failure["failure_kind"].getStr() == "infra",
      "missing credentials classified as infra failure"
    check outcome.failure["failure_code"].getStr() == "llm_missing_credentials",
      "missing credentials records llm_missing_credentials code"
    check not outcome.failure.hasKey("scores") and not outcome.failure.hasKey("win"),
      "missing credentials failure carries no authoritative gameplay scores or winners"

  block scriptedCertificationCompletesOffline:
    let outcome = runEpisode(
      gameBin, playerBin, tmpBase / "scripted-cert",
      "",
      ["steward", "steward", "stripper"]
    )
    check outcome.gameExit == 0,
      "purely scripted offline certification exits 0; log:\n" & outcome.gameLog
    check outcome.resultsExists,
      "purely scripted offline certification writes results.json"
    check not outcome.failureExists,
      "purely scripted offline certification writes no player_failure.json"
    check outcome.results["reason"].getStr() == "complete",
      "purely scripted offline certification completes normally"

  echo "test_roundtrip: ", checks, " checks passed"

main()
