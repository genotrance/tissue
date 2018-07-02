import httpclient, json, os, ospaths, osproc, parsecfg, pegs, rdstdin, streams,
  strutils, tables, threadpool, times, uri

type
  ConfigObj = object
    category, direction, nimdir, nim, nimtemp, token: string
    comment, debug, edit, foreground, force, noncrash, pr, verbose, write: bool
    first, issue, last, per_page, timeout: int

var gConfig {.threadvar.}: ConfigObj
gConfig = ConfigObj(
  category: "",
  direction: "asc",
  nimdir: "",
  nim: "",
  nimtemp: "",
  token: "",

  comment: false,
  debug: false,
  edit: false,
  foreground: false,
  force: false,
  noncrash: false,
  pr: false,
  verbose: false,
  write: false,

  first: 1,
  issue: 0,
  last: -1,
  per_page: 100,
  timeout: 10
)

var gIgnore: seq[string] = @[]

let HELP = """
Test failing snippets from Nim's issues

tissue [nimdir] [issueid] [tokenfile] [flags]

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

  -e      allow editing snippet before test
            requires <issueid> since expects user intervention
            implies running in the foreground

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
  -f      run tests in the foreground
            timeouts are no longer enforced
  -F      force write test case if exists    [default: false]
  -n      ignore check for compiler crash    [default: false]
  -T#     timeout before process is killed   [default: 10]

Pages:
  -pf#    first page to search from          [default: 1]
  -pl#    last page to stop processing
  -pn#    number of issues per page          [default: 100/max]
"""

# CTRL-C handler
proc chandler() {.noconv.} =
    setupForeignThreadGc()
    quit(1)
setControlCHook(chandler)

template decho(params: varargs[untyped]) =
  if gConfig.debug:
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

proc isMentioned(issue: JsonNode, search: varargs[string]): bool =
  let
    title = issue["title"].getStr().toLowerAscii()
    body = issue["body"].getStr().toLowerAscii()

  for srch in search:
    if srch in title or srch in body:
      return true

  return false

proc isNewruntime(issue: JsonNode): bool =
  return isMentioned(issue, "newruntime")

proc isCpp(issue: JsonNode): bool =
  return isMentioned(issue, "cpp", "c++")

proc isSsl(issue: JsonNode): bool =
  return isMentioned(issue, "ssl")

proc isThread(issue: JsonNode): bool =
  return isMentioned(issue, "thread")

proc isJS(issue: JsonNode): bool =
  return isMentioned(issue, " js ")

proc run(issue: JsonNode, snippet, nim: string, check=false): string =
  result = ""
  if nim.len() == 0:
    return

  var
    cmd = nim
    error = -1
    output = ""

  if check:
    cmd &= " check "
  elif isCpp(issue):
    cmd &= " cpp "
  elif isJS(issue):
    cmd &= " js "
  else:
    cmd &= " c "

  if isSsl(issue):
    cmd &= " -d:ssl "

  if isThread(issue):
    cmd &= " --threads:on "

  if isNewruntime(issue):
    cmd &= "--newruntime "

  let tempDir = getTempDir() / "tissue-" & $issue["number"]
  createDir(tempDir)

  let codefile = tempDir/"temp"
  cmd &= codefile

  let f = open(codefile & ".nim", fmWrite)
  f.write(snippet)
  f.close()

  if check == false and gConfig.edit:
    echo "Created " & codefile & ".nim"

  while true:
    if check == false and gConfig.edit:
      if readLineFromStdin("\nPress any key to run, q to quit: ").strip().
        toLowerAscii().strip() == "q":
        break

    try:
      if gConfig.foreground:
        error = execCmd(cmd)
      else:
        (result, error) = execCmdTimer(cmd, gConfig.timeout)
      if error == 0:
        try:
          cmd = codefile
          if isJS(issue):
            cmd = "node " & tempDir/"nimcache"/"temp.js"
          if gConfig.foreground:
            error = execCmd(cmd)
          else:
            (output, error) = execCmdTimer(cmd, gConfig.timeout)
            if output.len() != 0:
              result &= "\n\n" & output
            else:
              result &= "\n\nRan successfully, returned " & $error
        except OSError:
          result &= "\n\nFailed to run"
    except OSError:
      result = "Failed to compile"

    if not gConfig.edit:
      break

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
  decho "Getting page $# @ $# per page" % [$page, $gConfig.per_page]
  return newHttpClient(proxy = getProxy()).
    getContent("https://api.github.com/repos/nim-lang/nim/issues?direction=$#&per_page=$#&page=$#" %
      [gConfig.direction, $gConfig.per_page, $page]).parseJson()

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

proc getSnippet(issue: JsonNode): string =
  result = ""
  let
    body = issue["body"].getStr()
    bodylc = body.toLowerAscii()

  if body != "":
    var
      notnim = false
      start = -1
      endl = -1
      mark = ""
      s = 0
      run = ""
      runout = ""

    for line in bodylc.splitLines():
      if line =~ peg"{'```'[ ]*'nim'(rod)?}":
        start = bodylc.find(matches[0]) + matches[0].len()
        endl = body.find("```", start)
        break

    if start == -1:
      while "```" in body[s..^1]:
        start = body.find("```", s) + 3
        endl = body.find("```", start)
        if endl == -1:
          break
        s = endl + 1

        run = body[start..<endl].strip()
        runout = run(issue, run, gConfig.nim, check=true)
        if runout.find("undeclared") == -1:
          notnim = true
          break
        else:
          decho runout

      if not notnim:
        start = -1
        endl = -1

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
    result = "Still crashes with #head, full stacktrace below.\n\n"
  of "TIMEOUT":
    result = "Times out with #head.\n\n"

  result &= """
```
$#
-------- VERSION --------
$#
-------------------------
```
""" % [outverb, execCmdTimer(gConfig.nim & " -v", gConfig.timeout)[0]]

proc buildTestament(): bool =
  var
    cmd = gConfig.nim & " c --taintMode:on -d:nimCoroutines " &
      gConfig.nimdir/"tests"/"testament"/"tester"
    (output, error) = execCmdEx(cmd)

  return error == 0

proc testCategory(): bool =
  var
    cmd = gConfig.nimdir/"tests"/"testament"/"tester" &
      " \"--nim:" & "compiler"/"nim" & " \" cat " & gConfig.category
    error = 0

  withDir gConfig.nimdir:
    error = execCmd(cmd)

  echo cmd
  return error == 0

proc addTestcase(issueid, snippet, nimout: string): bool =
  let
    fn = gConfig.nimdir/"tests"/gConfig.category/"t$#.nim" % issueid

  if fileExists(fn):
    if not gConfig.force:
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

proc checkIssue(issue: JsonNode, config: ConfigObj) {.gcsafe.} =
  gConfig = config
  if "number" notin issue:
    return

  if gConfig.noncrash or isCrash(issue):
    let snippet = getSnippet(issue)
    var
      crashtype = "NOSNIPT"
      nimout = ""
      nimoutlc = ""
      nimouttemp = ""
      output = " - Issue $#: $#" % [$issue["number"], ($issue["title"]).strip(chars={'"', ' '})]
      outverb = ""

    if snippet != "":
      nimout = run(issue, snippet, gConfig.nim)
      nimouttemp = run(issue, snippet, gConfig.nimtemp)
      nimoutlc = nimout.toLowerAscii()

      crashtype = getCrashType(nimoutlc, nimouttemp)
      outverb = getVerbOut(snippet, nimout, nimouttemp)

    output = crashtype & output

    echo output
    if gConfig.verbose and outverb.len() != 0:
      echo "\n" & outverb

    if gConfig.write:
      createDir("logs")
      writeFile("logs"/crashtype & "-" & $issue["number"] & ".txt", output & "\n\n" & outverb)

    if gConfig.comment:
      commentIssue($issue["number"], getCommentOut(crashtype, outverb), gConfig.token)

    if gConfig.category.len() != 0:
      if not addTestcase($issue["number"], snippet, nimout) or not testCategory():
        echo "Test case failed"

proc checkAll() =
  var
    page = gConfig.first
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
      if $issue["number"] in gIgnore:
        continue

      spawn checkIssue(issue, gConfig)

    page += 1
    if gConfig.last != -1 and page > gConfig.last:
      break

  sync()

proc findNim(dir, nim: string): string =
  result = dir/"bin"/(@[nim, ExeExt].join(".").strip(chars={'.'}))
  if not fileExists(result):
    result = ""

proc loadCfg() =
  for cfile in @[getCurrentDir()/"ti.cfg", getAppDir()/"ti.cfg"]:
    if fileExists(cfile):
      var cfg = loadConfig(cfile)
      if cfg.hasKey("config"):
        for key in cfg["config"].keys:
          if key == "nimdir":
            if dirExists(cfg["config"][key]):
              gConfig.nimdir = cfg["config"][key]
              gConfig.nim = findNim(cfg["config"][key], "nim")
              gConfig.nimtemp = findNim(cfg["config"][key], "nim_temp")
            else:
              echo "Bad nimdir in cfg: " & cfg["config"][key]
          elif key == "tokenfile":
            if fileExists(cfg["config"][key]):
              gConfig.token = readFile(cfg["config"][key]).strip()
            else:
              echo "Bad tokenfile in cfg: " & cfg["config"][key]
          elif key in @["descending", "foreground", "force", "noncrash", "verbose", "write"]:
            if cfg["config"][key] == "true":
              if key == "descending":
                gConfig.direction = "desc"
              elif key == "edit":
                gConfig.edit = true
                gConfig.foreground = true
              elif key == "foreground":
                gConfig.foreground = true
              elif key == "force":
                gConfig.force = true
              elif key == "noncrash":
                gConfig.noncrash = true
              elif key == "verbose":
                gConfig.verbose = true
              elif key == "write":
                gConfig.write = true
          else:
            echo "Unknown key in cfg: " & key

      if cfg.hasKey("ignore"):
        for key in cfg["ignore"].keys:
          if key.len() > 0 and key[0] != '#':
            gIgnore.add(key.split(" ")[0])

      break

proc parseCli() =
  for param in commandLineParams():
    if dirExists(param):
      gConfig.nimdir = param
      gConfig.nim = findNim(param, "nim")
      gConfig.nimtemp = findNim(param, "nim_temp")
    elif fileExists(param):
      gConfig.token = readFile(param).strip()
    elif param[0..<2] == "-a":
      gConfig.category = param[2..^1]
    elif param == "-c":
      gConfig.comment = true
    elif param == "-d":
      gConfig.direction = "desc"
    elif param == "-e":
      gConfig.edit = true
      gConfig.foreground = true
    elif param == "-f":
      gConfig.foreground = true
    elif param == "-F":
      gConfig.force = true
    elif param == "-n":
      gConfig.noncrash = true
    elif param == "-o":
      gConfig.write = true
    elif param == "-p":
      gConfig.pr = true
    elif param[0..<2] == "-T":
      gConfig.timeout = parseInt(param[2..^1])
      if gConfig.first < 1:
        echo "Bad timeout"
        quit(1)
    elif param == "-v":
      gConfig.verbose = true
    elif param == "-h":
      echo HELP
      quit(0)
    elif param[0..<3] == "-pf":
      gConfig.first = parseInt(param[3..^1])
      if gConfig.first < 1:
        echo "Bad first page"
        quit(1)
    elif param[0..<3] == "-pl":
      gConfig.last = parseInt(param[3..^1])
      if gConfig.last < 1:
        echo "Bad last page"
        quit(1)
    elif param[0..<3] == "-pn":
      gConfig.per_page = parseInt(param[3..^1])
      if gConfig.per_page < 1 or gConfig.per_page > 100:
        echo "Bad per page"
        quit(1)
    elif param == "--debug":
      gConfig.debug = true
    else:
      try:
        gConfig.issue = parseInt(param)
      except:
        discard

  if gConfig.comment == true and gConfig.token.len() == 0:
    echo "Require token for commenting"
    quit(1)

  if gConfig.category.len() == 0:
    if gConfig.pr:
      echo "Require -a<dir> for -p"
      quit(1)
  else:
    if gConfig.nimdir.len() == 0:
      echo "Require <nimdir> for adding test case"
      quit(1)
    elif gConfig.issue == 0:
      echo "Require <issueid> for adding test case"
      quit(1)
    else:
      if not dirExists(gConfig.nimdir/"tests"/gConfig.category):
        echo "Not a nim test category: " & gConfig.category
        quit(1)

      if not buildTestament():
        echo "Failed in building testament"

  if gConfig.nim == "":
    gConfig.nim = findExe("nim")

  if gConfig.nimtemp == "":
    gConfig.nimtemp = findExe("nim_temp")

  if gConfig.nim == "" and gConfig.nimtemp == "":
    echo "Nim compiler missing"
    quit(1)

proc main() =
  loadCfg()
  parseCli()

  if gConfig.issue != 0:
    checkIssue(getIssue(gConfig.issue), gConfig)
  else:
    checkAll()

main()
