## Public host + player round-trip tests against the real `factory-commons`
## server binary and `factory-commons-player` binary.
##
## Verifies:
##   1. Native model player (no PLAYER_SCRIPTED) with bare JSON reply completes,
##      executes the model-produced action, and writes scored results + replay.
##   2. Native model player with Markdown-fenced JSON reply completes and
##      executes the model-produced action.
##   3. Invalid/ambiguous model reply fails non-zero without retrying, writes
##      Coworld's closed GamePlayerFailure JSON with kind="player_error" for the
##      actual failing seat, logs detailed diagnostics, and writes NO results.json.
##   4. Provider outage (HTTP 503) fails non-zero without retrying, writes
##      Coworld's closed GamePlayerFailure JSON with kind="episode_inconclusive"
##      for the actual interrupted seat, and writes NO results.json.
##   5. Missing LLM credentials on native model player fails non-zero with
##      kind="episode_inconclusive" and NO results.json.
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
log_path = sys.argv[3]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 0:
            self.rfile.read(length)
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "slot": self.headers.get("X-Coworld-Player-Slot")
            }) + "\n")
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

proc startStubSidecar(status: int, body, logPath: string): tuple[procObj: Process, port: int] =
  if fileExists(logPath):
    removeFile(logPath)
  let p = startProcess(
    "python3",
    args = ["-u", "-c", StubServerScript, $status, body, logPath],
    options = {poUsePath}
  )
  let line = p.outputStream().readLine().strip()
  result = (p, parseInt(line))

proc readStubCalls(logPath: string): seq[JsonNode] =
  if not fileExists(logPath):
    return @[]
  for line in readFile(logPath).splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.add(parseJson(trimmed))

proc checkClosedPlayerFailure(failure: JsonNode, expectedSeat: int,
    expectedKind, label: string) =
  check failure.kind == JObject, label & ": failure is a JSON object"
  check failure.len == 3,
    label & ": closed GamePlayerFailure has exactly 3 keys, got " & $failure
  check failure.hasKey("failed_policy_index") and
    failure.hasKey("kind") and failure.hasKey("message"),
    label & ": closed GamePlayerFailure has exact keys"
  check failure["failed_policy_index"].kind == JInt and
    failure["failed_policy_index"].getInt() == expectedSeat,
    label & ": failed_policy_index == " & $expectedSeat & ", got " &
    $failure["failed_policy_index"]
  check failure["kind"].kind == JString and
    failure["kind"].getStr() == expectedKind,
    label & ": kind == " & expectedKind & ", got " & $failure["kind"]
  check failure["message"].kind == JString and
    failure["message"].getStr().len >= 1 and
    failure["message"].getStr().len <= 2000,
    label & ": message length in 1..2000"

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
    let callsPath = tmpBase / "bare-calls.jsonl"
    let stub = startStubSidecar(200, anthropicTextBody(
      """{"job":"maintain","cube":"pink","say":"model-bare-json","notes":"ok"}"""),
      callsPath)
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
    let callsPath = tmpBase / "fenced-calls.jsonl"
    let fenced = "```json\n" &
      """{"job":"eat","cube":"any","say":"model-fenced-json","notes":"fenced"}""" &
      "\n```"
    let stub = startStubSidecar(200, anthropicTextBody(fenced), callsPath)
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
    let callsPath = tmpBase / "invalid-calls.jsonl"
    let ambiguous = """Here is my move: {"job":"operate"} {"job":"idle"}"""
    let stub = startStubSidecar(200, anthropicTextBody(ambiguous), callsPath)
    defer:
      stub.procObj.terminate()
      discard stub.procObj.waitForExit(timeout = 2_000)
      stub.procObj.close()

    let outcome = runEpisode(
      gameBin, playerBin, tmpBase / "invalid-reply",
      "http://127.0.0.1:" & $stub.port,
      ["steward", "", "stripper"]
    )
    check outcome.gameExit != 0,
      "invalid/ambiguous reply exits non-zero; log:\n" & outcome.gameLog
    check not outcome.resultsExists,
      "invalid/ambiguous reply writes NO results.json (no numeric results)"
    check outcome.failureExists,
      "invalid/ambiguous reply writes player_failure.json"
    checkClosedPlayerFailure(outcome.failure, 1, "player_error", "invalid reply")
    check readStubCalls(callsPath).len == 1,
      "invalid/ambiguous reply issues 1 request without retrying"
    check "model_invalid_action/llm_invalid_reply" in outcome.gameLog and
      "rejected_action=" in outcome.gameLog,
      "game diagnostics log preserves model_invalid_action and rejected_action"

  block providerFailure503FailsUnscored:
    let callsPath = tmpBase / "provider-503-calls.jsonl"
    let stub = startStubSidecar(503, """{"error":"service unavailable"}""", callsPath)
    defer:
      stub.procObj.terminate()
      discard stub.procObj.waitForExit(timeout = 2_000)
      stub.procObj.close()

    let outcome = runEpisode(
      gameBin, playerBin, tmpBase / "provider-503",
      "http://127.0.0.1:" & $stub.port,
      ["", "steward", "stripper"]
    )
    check outcome.gameExit != 0,
      "provider 503 exits non-zero; log:\n" & outcome.gameLog
    check not outcome.resultsExists,
      "provider 503 writes NO results.json (no numeric results)"
    check outcome.failureExists,
      "provider 503 writes player_failure.json"
    checkClosedPlayerFailure(outcome.failure, 0, "episode_inconclusive", "provider 503")
    check "503" in outcome.failure["message"].getStr(),
      "provider 503 message preserves HTTP 503 cause"
    check readStubCalls(callsPath).len == 1,
      "provider 503 issues 1 request without retrying"
    check "infra/llm_provider_error" in outcome.gameLog,
      "game diagnostics log preserves infra/llm_provider_error"

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
    checkClosedPlayerFailure(outcome.failure, 0, "episode_inconclusive",
      "missing credentials")
    check "llm_missing_credentials" in outcome.failure["message"].getStr(),
      "missing credentials message preserves cause"

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
