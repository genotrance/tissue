import httpclient, json, os, ospaths, osproc, streams, strutils, threadpool,
  times, uri

var
  COMMENT = false
  DEBUG = false
  DIRECTION = "asc"
  FIRST = 1
  ISSUE = 0
  LAST = -1
  NIM = ""
  NIMTEMP = ""
  PER_PAGE = 100
  TIMEOUT = 10
  TOKEN = ""
  VERBOSE = false
  WRITE = false

let HELP = """
Test failing snippets from Nim's issues

tissue [nimdir] [issueid] [tokenfile] [-dhov] [-fln#]

  If nimdir specified on command line:
    Look for nimdir\bin\nim
    Look for nimdir\bin\nim_temp

  If either not found:
    Look for nim in path
    Look for nim_temp in path

  If no issue ID, run through all issues

  If -c specified, require tokenfile which contains github auth token

  -c      post comment on issue with run details
  -d      sort in descending order [default: asc]
  -f#     page number to start [default: 1]
  -n#     number of issues per page [default: 100/max]
  -l#     page to stop processing
  -o      write verbose output to logs\issueid.txt
  -t#     timeout in seconds before process is killed [default: 10]
  -v      write verbose output to stdout
  -h"""

# CTRL-C handler
proc chandler() {.noconv.} =
    setupForeignThreadGc()
    quit(1)
setControlCHook(chandler)

template decho(params: varargs[untyped]) =
  if DEBUG:
    echo params

proc execCmdTimer(command: string, timer: int): tuple[output: string, error: int] =
  result = ("", -1)
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

  while outp.readLine(line):
    result[0].add(line)
    result[0].add("\n")

  result[1] = p.peekExitCode()

  if killed:
    result[0].add("Timed out - killed")
    result[1] = -1
  p.close()

  result[0] = result[0].strip()

proc run(issueid, snippet, nim: string, newruntime = false): string =
  result = ""
  if nim.len() == 0:
    return

  var
    cmd = nim & " c "
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
    (result, error) = execCmdTimer(cmd, TIMEOUT)
    if error == 0:
      try:
        (result, error) = execCmdTimer(codefile, TIMEOUT)
      except OSError:
        result = "Failed to run"
  except OSError:
    result = "Failed to compile"

  # Wait for rmdir since process was killed
  if error == -1:
    sleep(1000)

  try:
    removeDir(tempDir)
  except:
    decho "Failed to delete " & tempDir
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
  decho "Getting page $# @ $# per page" % [$page, $PER_PAGE]
  return newHttpClient(proxy = getProxy()).
    getContent("https://api.github.com/repos/nim-lang/nim/issues?direction=$#&per_page=$#&page=$#" %
      [DIRECTION, $PER_PAGE, $page]).parseJson()

proc getIssue(issue: int): JsonNode =
  decho "Getting issue $#" % $issue
  return newHttpClient(proxy = getProxy()).
    getContent("https://api.github.com/repos/nim-lang/nim/issues/" & $issue).
    parseJson()

proc getAuth(token: string): HttpHeaders =
  return newHttpHeaders({"Authorization": "token " & token})

proc commentIssue(issueid, text, token: string) =
  var body = %*
    {
      "body": text
    }
  decho "Commenting on issue " & issueid

  var cl = newHttpClient(proxy = getProxy())
  cl.headers = getAuth(token)
  var res = cl.request("https://api.github.com/repos/nim-lang/nim/issues/$#/comments" % issueid,
    httpMethod = HttpPost, body = $body)
  if "201" notin res.status:
    echo "Failed to create comment"
    echo res.body

proc isCrash(issue: JsonNode): bool =
  if "pull_request" in issue:
    return false

  let
    title = issue["title"].getStr().toLowerAscii()
    body = issue["body"].getStr().toLowerAscii()

  for ctype in ["crash", " ice ", "internal error"]:
    if ctype in title or ctype in body:
      return true

  if (title.len() > 4 and (title[0..<4] == "ice " or title[^4..^1] == " ice")) or
    (body.len() > 4 and (body[0..<4] == "ice " or body[^4..^1] == " ice")):
      return true

  return false

proc isNewruntime(issue: JsonNode): bool =
  if "newruntime" in issue["title"].getStr() or
    "newruntime" in issue["body"].getStr():
      return true

  return false

proc getSnippet(issue: JsonNode): string =
  result = ""
  let body = issue["body"].getStr()
  if body != "":
    var
      notnim = false
      start = -1
      endl = -1

    if "``` nimrod" in body.toLowerAscii():
      start = body.toLowerAscii().find("``` nimrod") + 10
    elif "```nimrod" in body.toLowerAscii():
      start = body.toLowerAscii().find("```nimrod") + 9
    elif "``` nim" in body.toLowerAscii():
      start = body.toLowerAscii().find("``` nim") + 7
    elif "```nim" in body.toLowerAscii():
      start = body.toLowerAscii().find("```nim") + 6
    elif "```\n" in body:
      start = body.find("```\n") + 4
      notnim = true

    if start != -1:
      endl = body.find("```", start+1)

    if start != -1 and endl != -1:
      if notnim:
        result = "# Snippet not defined as ```nim\n\n"

      result &= body[start..<endl].strip()

proc checkIssue(issue: JsonNode, verbose, write, comment: bool, nim, nimtemp, token: string) {.gcsafe.} =
  if "number" notin issue:
    return

  if isCrash(issue):
    let snippet = getSnippet(issue)
    var
      output = " - Issue $#: $#" % [$issue["number"], ($issue["title"]).strip(chars={'"', ' '})]
      outverb = ""
      cdata = ""

    if snippet != "":
      let
        nimout = run($issue["number"], snippet, nim, isNewruntime(issue))
        nimouttemp = run($issue["number"], snippet, nimtemp, isNewruntime(issue))
        nimoutlc = nimout.toLowerAscii()

      if "internal error" in nimoutlc or "illegal storage" in nimoutlc:
        output = "CRASHED" & output
      elif "timed out" in nimoutlc:
        output = "TIMEOUT" & output
      else:
        output = "NOCRASH" & output

      outverb = """
-------- SNIPPET --------
$#
-------------------------

-------- OUTPUT --------
$#
------------------------
""" % [snippet, nimout]

      if nimouttemp.len() != 0:
        outverb &= """

-------- NIMTEMP --------
$#
-------------------------
""" % nimouttemp
    else:
      output = "NOSNIPT" & output

    echo output
    if verbose:
      echo "\n" & outverb
    if write:
      createDir("logs")
      writeFile(joinPath("logs", output[0..<7] & "-" & $issue["number"] & ".txt"), output & "\n\n" & outverb)

    if comment:
      if "NOCRASH" in output:
        cdata = "No longer crashes with #head.\n\n"
      elif "CRASHED" in output:
        cdata = "Still crashes with #head\n\n"

      cdata &= """
```
$#
-------- VERSION --------
$#
-------------------------
```
""" % [outverb, execCmdTimer(nim & " -v", TIMEOUT)[0]]

      commentIssue($issue["number"], cdata, token)

proc checkAll() =
  var
    page = FIRST
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
      spawn checkIssue(issue, VERBOSE, WRITE, COMMENT, NIM, NIMTEMP, TOKEN)

    page += 1
    if LAST != -1 and page > LAST:
      break

proc findNim(dir, nim: string): string =
  result = joinPath(dir, "bin", @[nim, ExeExt].join(".").strip(chars={'.'}))
  if not fileExists(result):
    result = ""

proc parseCli() =
  for param in commandLineParams():
    if dirExists(param):
      NIM = findNim(param, "nim")
      NIMTEMP = findNim(param, "nim_temp")
    elif fileExists(param):
      TOKEN = readFile(param).strip()
    elif param == "-c":
      COMMENT = true
    elif param == "-d":
      DIRECTION = "desc"
    elif param[0..<2] == "-f":
      FIRST = parseInt(param[2..^1])
      if FIRST < 1:
        echo "Bad first page"
        quit(1)
    elif param[0..<2] == "-n":
      PER_PAGE = parseInt(param[2..^1])
      if PER_PAGE < 1 or PER_PAGE > 100:
        echo "Bad per page"
        quit(1)
    elif param[0..<2] == "-l":
      LAST = parseInt(param[2..^1])
      if LAST < 1:
        echo "Bad last page"
        quit(1)
    elif param == "-o":
      WRITE = true
    elif param[0..<2] == "-t":
      FIRST = parseInt(param[2..^1])
      if FIRST < 1:
        echo "Bad timeout"
        quit(1)
    elif param == "-v":
      VERBOSE = true
    elif param == "-h":
      echo HELP
      quit(0)
    elif param == "--debug":
      DEBUG = true
    else:
      try:
        ISSUE = parseInt(param)
      except:
        discard

  if COMMENT == true and TOKEN.len() == 0:
    echo "Require token for commenting"
    quit(1)

  if NIM == "":
    NIM = findExe("nim")

  if NIMTEMP == "":
    NIMTEMP = findExe("nim_temp")

  if NIM == "" and NIMTEMP == "":
    echo "Nim compiler missing"
    quit(1)

proc main() =
  parseCli()

  if ISSUE != 0:
    checkIssue(getIssue(ISSUE), VERBOSE, WRITE, COMMENT, NIM, NIMTEMP, TOKEN)
  else:
    checkAll()

main()
