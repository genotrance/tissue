import httpclient, json, os, ospaths, osproc, pegs, streams, strutils,
  threadpool, times, uri

type
  tconfig = object
    category, direction, nimdir, nim, nimtemp, token: string
    comment, debug, force, pr, verbose, write: bool
    first, issue, last, per_page, timeout: int

var CONFIG {.threadvar.}: tconfig
CONFIG = tconfig(
  category: "",
  direction: "asc",
  nimdir: "",
  nim: "",
  nimtemp: "",
  token: "",

  comment: false,
  debug: false,
  force: false,
  pr: false,
  verbose: false,
  write: false,

  first: 1,
  issue: 0,
  last: -1,
  per_page: 100,
  timeout: 10
)

let HELP = """
Test failing snippets from Nim's issues

tissue [nimdir] [issueid] [tokenfile] [-dhov] [-fln#]

  If <nimdir> specified on command line:
    Look for <nimdir>\bin\nim
    Look for <nimdir>\bin\nim_temp

  If either not found:
    Look for nim in path
    Look for nim_temp in path

  If no <issueid>:
    Run through all issues

Actions:
  -a<cat> add and verify test case <nimdir>/tests/<cat>/t<issueid>.nim
            requires <nimdir> where test case can be created and tested
            requires <issueid> since test category is issue specific

  -c      post comment on issue with run details
            requires <tokenfile> which contains github auth token

  -p      create branch #<issueid>, commit test case (-a), push, create PR
            requires -a<cat> and <issueid>
            requires <nimdir> where test case is pushed
            requires <tokenfile> which contains github auth token
            NOTE: <nimdir> should be fork of nim-lang/Nim that can be written
                  to by github auth token specified

Output:
  -h      this help screen
  -o      write verbose output to logs\issueid.txt
  -v      write verbose output to stdout

Settings:
  -d      sort in descending order           [default: asc]
  -F      force write test case if exists    [default: false]
  -f#     page number to start               [default: 1]
  -n#     number of issues per page          [default: 100/max]
  -l#     page to stop processing
  -T#     timeout before process is killed   [default: 10]
"""

# CTRL-C handler
proc chandler() {.noconv.} =
    setupForeignThreadGc()
    quit(1)
setControlCHook(chandler)

template decho(params: varargs[untyped]) =
  if CONFIG.debug:
    echo params

template withDir*(dir: string; body: untyped): untyped =
  var curDir = getCurrentDir()
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(curDir)

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

  let codefile = tempDir/"temp"
  cmd &= codefile

  let f = open(codefile & ".nim", fmWrite)
  f.write(snippet)
  f.close()

  try:
    (result, error) = execCmdTimer(cmd, CONFIG.timeout)
    if error == 0:
      try:
        (result, error) = execCmdTimer(codefile, CONFIG.timeout)
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
  decho "Getting page $# @ $# per page" % [$page, $CONFIG.per_page]
  return newHttpClient(proxy = getProxy()).
    getContent("https://api.github.com/repos/nim-lang/nim/issues?direction=$#&per_page=$#&page=$#" %
      [CONFIG.direction, $CONFIG.per_page, $page]).parseJson()

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

proc getCrashType(nimoutlc, nimouttemp: string): string =
  result = "NOCRASH"
  if "internal error" in nimoutlc or "illegal storage" in nimoutlc or
    "Stack overflow" in nimouttemp:
    result = "CRASHED"
  elif "timed out" in nimoutlc:
    result = "TIMEOUT"

proc getVerbOut(snippet, nimout, nimouttemp: string): string =
  result = """
-------- SNIPPET --------
$#
-------------------------

-------- OUTPUT --------
$#
------------------------
""" % [snippet, nimout]

  if nimouttemp.len() != 0:
    result &= """

-------- NIMTEMP --------
$#
-------------------------
""" % nimouttemp

proc getCommentOut(crashtype, outverb: string): string =
  case crashtype
  of "NOCRASH":
    result = "No longer crashes with #head.\n\n"
  of "CRASHED":
    result = "Still crashes with #head\n\n"
  of "TIMEOUT":
    result = "Times out with #head\n\n"

  result &= """
```
$#
-------- VERSION --------
$#
-------------------------
```
""" % [outverb, execCmdTimer(CONFIG.nim & " -v", CONFIG.timeout)[0]]

proc buildTestament(): bool =
  var
    cmd = CONFIG.nim & " c --taintMode:on -d:nimCoroutines " &
      CONFIG.nimdir/"tests"/"testament"/"tester"
    (output, error) = execCmdEx(cmd)

  return error == 0

proc testCategory(): bool =
  var
    cmd = CONFIG.nimdir/"tests"/"testament"/"tester" &
      " \"--nim:" & "compiler"/"nim" & " \" cat " & CONFIG.category
    error = 0

  withDir CONFIG.nimdir:
    error = execCmd(cmd)

  echo cmd
  return error == 0

proc addTestcase(issueid, snippet, nimout: string): bool =
  let
    fn = CONFIG.nimdir/"tests"/CONFIG.category/"t$#.nim" % issueid

  if fileExists(fn):
    if not CONFIG.force:
      echo "Test case already exists, not overwriting: " & fn
      return false

  var errorStr = ""
  for line in nimout.splitLines():
    if line =~ peg"""'temp.nim'\({\d+}', '+\d+\)' Error: '{.+}""":
      errorStr = "discard \"\"\"\nerrormsg: \"$#\"\nline: $#\n\"\"\"\n\n" %
        [matches[1], $(parseInt(matches[0])+5)]
      break

  writeFile(fn, errorStr & snippet)

  return true

proc checkIssue(issue: JsonNode, config: tconfig) {.gcsafe.} =
  CONFIG = config
  if "number" notin issue:
    return

  if isCrash(issue):
    let snippet = getSnippet(issue)
    var
      crashtype = "NOSNIPT"
      nimout = ""
      nimoutlc = ""
      nimouttemp = ""
      output = " - Issue $#: $#" % [$issue["number"], ($issue["title"]).strip(chars={'"', ' '})]
      outverb = ""

    if snippet != "":
      nimout = run($issue["number"], snippet, CONFIG.nim, isNewruntime(issue))
      nimouttemp = run($issue["number"], snippet, CONFIG.nimtemp, isNewruntime(issue))
      nimoutlc = nimout.toLowerAscii()

      crashtype = getCrashType(nimoutlc, nimouttemp)
      outverb = getVerbOut(snippet, nimout, nimouttemp)

    output = crashtype & output

    echo output
    if CONFIG.verbose:
      echo "\n" & outverb

    if CONFIG.write:
      createDir("logs")
      writeFile("logs"/crashtype & "-" & $issue["number"] & ".txt", output & "\n\n" & outverb)

    if CONFIG.comment:
      echo getCommentOut(crashtype, outverb)
      #commentIssue($issue["number"], getCommentOut(crashtype, outverb), CONFIG.token)

    if CONFIG.category.len() != 0:
      if not addTestcase($issue["number"], snippet, nimout) or not testCategory():
        echo "Test case failed"

proc checkAll() =
  var
    page = CONFIG.first
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
      spawn checkIssue(issue, CONFIG)

    page += 1
    if CONFIG.last != -1 and page > CONFIG.last:
      break

  sync()

proc findNim(dir, nim: string): string =
  result = dir/"bin"/(@[nim, ExeExt].join(".").strip(chars={'.'}))
  if not fileExists(result):
    result = ""

proc parseCli() =
  for param in commandLineParams():
    if dirExists(param):
      CONFIG.nimdir = param
      CONFIG.nim = findNim(param, "nim")
      CONFIG.nimtemp = findNim(param, "nim_temp")
    elif fileExists(param):
      CONFIG.token = readFile(param).strip()
    elif param[0..<2] == "-a":
      CONFIG.category = param[2..^1]
    elif param == "-c":
      CONFIG.comment = true
    elif param == "-d":
      CONFIG.direction = "desc"
    elif param == "-F":
      CONFIG.force = true
    elif param[0..<2] == "-f":
      CONFIG.first = parseInt(param[2..^1])
      if CONFIG.first < 1:
        echo "Bad first page"
        quit(1)
    elif param[0..<2] == "-n":
      CONFIG.per_page = parseInt(param[2..^1])
      if CONFIG.per_page < 1 or CONFIG.per_page > 100:
        echo "Bad per page"
        quit(1)
    elif param[0..<2] == "-l":
      CONFIG.last = parseInt(param[2..^1])
      if CONFIG.last < 1:
        echo "Bad last page"
        quit(1)
    elif param == "-o":
      CONFIG.write = true
    elif param == "-p":
      CONFIG.pr = true
    elif param[0..<2] == "-T":
      CONFIG.first = parseInt(param[2..^1])
      if CONFIG.first < 1:
        echo "Bad timeout"
        quit(1)
    elif param == "-v":
      CONFIG.verbose = true
    elif param == "-h":
      echo HELP
      quit(0)
    elif param == "--debug":
      CONFIG.debug = true
    else:
      try:
        CONFIG.issue = parseInt(param)
      except:
        discard

  if CONFIG.comment == true and CONFIG.token.len() == 0:
    echo "Require token for commenting"
    quit(1)

  if CONFIG.category.len() == 0:
    if CONFIG.pr:
      echo "Require -a<dir> for -p"
      quit(1)
  else:
    if CONFIG.nimdir.len() == 0:
      echo "Require <nimdir> for adding test case"
      quit(1)
    elif CONFIG.issue == 0:
      echo "Require <issueid> for adding test case"
      quit(1)
    else:
      if not dirExists(CONFIG.nimdir/"tests"/CONFIG.category):
        echo "Not a nim test category: " & CONFIG.category
        quit(1)

      if not buildTestament():
        echo "Failed in building testament"

  if CONFIG.nim == "":
    CONFIG.nim = findExe("nim")

  if CONFIG.nimtemp == "":
    CONFIG.nimtemp = findExe("nim_temp")

  if CONFIG.nim == "" and CONFIG.nimtemp == "":
    echo "Nim compiler missing"
    quit(1)

proc main() =
  parseCli()

  if CONFIG.issue != 0:
    checkIssue(getIssue(CONFIG.issue), CONFIG)
  else:
    checkAll()

main()
