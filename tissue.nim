import httpclient, json, os, ospaths, osproc, streams, strutils, threadpool,
  times, uri

var NIMFILE = ""
var ISSUE = 0
var VERBOSE = false
var WRITE = false

let HELP = """
Test failing snippets from Nim's issues

tissue [nimdir] [issueid] [-o] [-v]

  If path specified on command line:
    First look for path\bin\nim_temp
    Next look for path\bin\nim

  If neither found:
    Look for nim_temp in path
    Look for nim in path

  If no issue ID, run through all issues

  -o  write verbose output to logs\issueid.txt
  -v  write verbose output to stdout
  -h"""

# CTRL-C handler
proc chandler() {.noconv.} =
    setupForeignThreadGc()
    quit(1)
setControlCHook(chandler)

proc execCmdTimer(command: string, timer: int): tuple[output: string, error: int] =
  result = (command & "\n\n", -1)
  let start = cpuTime()
  var
    p = startProcess(command, options={poStdErrToStdOut, poUsePath, poEvalCommand})
    outp = p.outputStream()
    line = newStringOfCap(120)
    killed = false

  while p.peekExitCode() == -1:
    sleep(10)
    if p.hasData():
      if outp.readLine(line):
        result[0].add(line)
        result[0].add("\n")

    if timer != 0 and cpuTime() - start > timer.float:
      p.kill()
      killed = true
      break

  result[1] = p.peekExitCode()

  if killed:
    result[0].add("Timed out - killed")
    result[1] = -1
  p.close()

proc run(issueid, snippet, nimfile: string, newruntime = false): string =
  result = ""
  var
    cmd = nimfile & " c "
    error = -1

  if newruntime:
    cmd &= "--newruntime "

  let tempDir = getTempDir() / "tissue-" & issueid
  createDir(tempDir)

  let codefile = joinPath(tempDir, "temp")
  cmd &= codefile

  let f = open(codefile & ".nim", fmWrite)
  f.write(snippet)
  f.close()

  try:
    (result, error) = execCmdTimer(cmd, 10)
    if error == 0:
      try:
        (result, error) = execCmdTimer(codefile, 10)
      except OSError:
        result = "Failed to run"
  except OSError:
    result = "Failed to compile"

  # Wait for rmdir since process was killed
  if error == -1:
    sleep(1000)

  removeDir(tempDir)
  return result

proc getProxy(): Proxy =
  var url = ""
  try:
    if existsEnv("http_proxy"):
      url = getEnv("http_proxy")
    elif existsEnv("https_proxy"):
      url = getEnv("https_proxy")
  except ValueError:
    echo "Unable to parse proxy from environment: " & getCurrentExceptionMsg()

  if url.len > 0:
    var parsed = parseUri(url)
    if parsed.scheme.len == 0 or parsed.hostname.len == 0:
      parsed = parseUri("http://" & url)
    let auth =
      if parsed.username.len > 0: parsed.username & ":" & parsed.password
      else: ""
    return newProxy($parsed, auth)
  else:
    return nil

proc getIssues(page = 1): JsonNode =
  return newHttpClient(proxy = getProxy()).
    getContent("https://api.github.com/repos/nim-lang/nim/issues?page=" & $page).
    parseJson()

proc getIssue(issue: int): JsonNode =
  return newHttpClient(proxy = getProxy()).
    getContent("https://api.github.com/repos/nim-lang/nim/issues/" & $issue).
    parseJson()

proc isCrash(issue: JsonNode): bool =
  if "pull_request" in issue:
    return false

  let
    title = ($issue["title"]).toLowerAscii()
    body = ($issue["body"]).toLowerAscii()

  for ctype in ["crash", " ice ", "internal error"]:
    if ctype in title or ctype in body:
      return true

  if (title.len() > 4 and (title[0..<4] == "ice " or title[^4..^1] == " ice")) or
    (body.len() > 4 and (body[0..<4] == "ice " or body[^4..^1] == " ice")):
      return true

  return false

proc isNewruntime(issue: JsonNode): bool =
  if "newruntime" in $issue["title"] or
    "newruntime" in $issue["body"]:
      return true

  return false

proc getSnippet(issue: JsonNode): string =
  result = ""
  let body = $issue["body"]
  if body != "":
    var
      notnim = false
      start = -1
      endl = -1

    if "```nim" in body:
      start = body.find("```nim") + 6
    elif "```" in body:
      start = body.find("```") + 3
      notnim = true

    if start != -1:
      endl = body.find("```", start+1)

    if start != -1 and endl != -1:
      if notnim:
        result = "# Snippet not defined as ```nim\n\n"

      result &= body[start..<endl].replace("\\r\\n", "\n").replace("\\\"", "\"").strip()

proc checkIssue(issue: JsonNode, verbose, write: bool, nimfile: string) {.gcsafe.} =
  if "number" notin issue:
    return

  if isCrash(issue):
    let snippet = getSnippet(issue)
    var
      output = " - Issue $#: $#" % [$issue["number"], ($issue["title"]).strip(chars={'"', ' '})]
      outverb = ""

    if snippet != "":
      let
        nimout = run($issue["number"], snippet, nimfile, isNewruntime(issue)).strip()
        nimoutlc = nimout.toLowerAscii()

      if "internal error" in nimoutlc or "illegal storage" in nimoutlc:
        output = "CRASHED" & output
      elif "timed out" in nimoutlc:
        output = "TIMEOUT" & output
      else:
        output = "NOCRASH" & output

      outverb = """$#

-------- SNIPPET --------
$#
-------------------------

-------- OUTPUT --------
$#
------------------------""" % [output, snippet, nimout]
    else:
      output = "NOSNIPT" & output

    if verbose:
      echo outverb
    else:
      echo output

    if write:
      createDir("logs")
      writeFile(joinPath("logs", output[0..<7] & "-" & $issue["number"] & ".txt"), outverb)

proc checkAll() =
  var
    page = 1
    issues: JsonNode

  while true:
    try:
      issues = getIssues(page)
    except ProtocolError:
      sleep(1000)
      continue

    if issues.len() == 0:
      break

    for issue in issues:
      spawn checkIssue(issue, VERBOSE, WRITE, NIMFILE)

    page += 1

proc parseCli() =
  for param in commandLineParams():
    if dirExists(param):
      for nimexe in @["nim_temp", "nim"]:
        var fn = joinPath(param, "bin", @[nimexe, ExeExt].join(".").strip(chars={'.'}))
        if fileExists(fn):
          NIMFILE = fn
          break
    elif param == "-v":
      VERBOSE = true
    elif param == "-o":
      WRITE = true
    elif param == "-h":
      echo HELP
      quit(0)
    else:
      try:
        ISSUE = parseInt(param)
      except:
        discard

  if NIMFILE == "":
    NIMFILE = findExe("nim_temp")

  if NIMFILE == "":
    NIMFILE = findExe("nim")

proc main() =
  parseCli()

  if ISSUE != 0:
    checkIssue(getIssue(ISSUE), VERBOSE, WRITE, NIMFILE)
  else:
    checkAll()

main()
