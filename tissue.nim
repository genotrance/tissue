import httpclient, json, os, ospaths, osproc, parsecfg, pegs, rdstdin, streams,
  strutils, tables, threadpool, times, uri

type
  ConfigObj = object
    category, direction, mode, nimdir, nim, nimtemp, token: string
    comment, debug, edit, foreground, force, noncrash, noverify, pr, verbose, write: bool
    commno, first, issue, last, per_page, snipno, timeout: int

var gConfig {.threadvar.}: ConfigObj
gConfig = ConfigObj(
  category: "",
  direction: "asc",
  mode: "",
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
  noverify: false,
  pr: false,
  verbose: false,
  write: false,

  commno: 0,
  first: 1,
  issue: 0,
  last: -1,
  per_page: 100,
  snipno: 1,
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

Inputs:
  -C#     get snippet from comment #         [default: 0 = from issue body]
  -mXX    force compiler to check/c/cpp/js   [default: c or as detected]
  -s#     snippet number                     [default: 1]

Settings:
  -d      sort in descending order           [default: asc]
  -f      run tests in the foreground
            timeouts are no longer enforced
  -F      force write test case if exists    [default: false]
  -k      skip test case verification        [default: false]
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
  result = false
  let
    title = issue["title"].getStr().toLowerAscii()
    body = issue["body"].getStr().toLowerAscii()

  for srch in search:
    if srch in title or srch in body:
      return true

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
    rcmd = ""
    error = -1
    output = ""

  if check:
    cmd &= " check "
  elif gConfig.mode.len() != 0:
    cmd &= " $# " % gConfig.mode
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

  rcmd = codefile
  if gConfig.mode == "js" or (gConfig.mode.len() == 0 and isJS(issue)):
    rcmd = "node " & tempDir/"nimcache"/"temp.js"

  if check == false and gConfig.edit:
    echo "Created " & codefile & ".nim"

  while true:
    if check == false and gConfig.edit:
      if readLineFromStdin("\nPress any key to run, q to quit: ").strip().
        toLowerAscii().strip() == "q":
        break

    try:
      if gConfig.foreground:
        echo "-------- $# --------" % [if nim == gConfig.nim: "OUTPUT" else: "NIMTEMP"]
        error = execCmd(cmd)
      else:
        (result, error) = execCmdTimer(cmd, gConfig.timeout)
      if error == 0:
        try:
          if gConfig.foreground:
            error = execCmd(rcmd)
          else:
            (output, error) = execCmdTimer(rcmd, gConfig.timeout)
            if output.len() != 0:
              result &= "\n\n" & output
            else:
              result &= "\n\nRan successfully, returned " & $error
        except OSError:
          result &= "\n\nFailed to run"
    except OSError:
      result = "Failed to compile"

    if gConfig.foreground:
      echo "-------------------------\n"

    if not gConfig.edit:
      break

  # Wait for rmdir since process was killed
  if error == -1:
    sleep(1000)

  try:
    removeDir(tempDir)
  except:
    decho "Failed to delete " & tempDir

proc getProxy(): Proxy =
  result = nil
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
    result = newProxy($parsed, auth)

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

proc getComments(issue: int): JsonNode =
  decho "Getting issue comments $#" % $issue
  return newHttpClient(proxy = getProxy()).
    getContent("https://api.github.com/repos/nim-lang/nim/issues/" & $issue & "/comments").
    parseJson()

proc getAuth(): HttpHeaders =
  return newHttpHeaders({"Authorization": "token " & gConfig.token})

proc commentIssue(issueid, text: string) =
  decho "Commenting on issue " & issueid
  var
    body = %*
      {
        "body": text
      }
    cl = newHttpClient(proxy = getProxy())

  cl.headers = getAuth()
  var res = cl.request("https://api.github.com/repos/nim-lang/nim/issues/$#/comments" % issueid,
    httpMethod = HttpPost, body = $body)
  if "201" notin res.status:
    echo "Failed to create comment"
    decho res.body

proc isCrash(issue: JsonNode): bool =
  result = false
  if "pull_request" in issue:
    return

  let
    title = issue["title"].getStr().toLowerAscii()
    body = issue["body"].getStr().toLowerAscii()

  for ctype in ["crash", " ice ", "internal error"]:
    if ctype in title or ctype in body:
      return true

  if (title.len() > 4 and (title[0..<4] == "ice " or title[^4..^1] == " ice")) or
    (body.len() > 4 and (body[0..<4] == "ice " or body[^4..^1] == " ice")):
      return true

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
      snipno = gConfig.snipno

    for line in bodylc.splitLines():
      if line =~ peg"{'```'[ ]*'nim'(rod)?}":
        start = bodylc.find(matches[0], s) + matches[0].len()
        endl = body.find("```", start)
        s = endl + 1

        if snipno > 1:
          snipno -= 1
          continue

        break

    if start == -1:
      s = 0
      snipno = gConfig.snipno
      while "```" in body[s..^1]:
        start = body.find("```", s) + 3
        endl = body.find("```", start)
        if endl == -1:
          break
        s = endl + 1

        if snipno > 1:
          snipno -= 1
          continue

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

proc getIssueDiscussion(issue, comments: JsonNode): string =
  result = """-------- ISSUE --------
$#
-----------------------
""" % issue["body"].getStr()

  var i = 0
  for comment in comments:
    i += 1
    result &= """
Comment $# by @$#

$#
-------------------------
""" % [$i, comment["user"]["login"].getStr(), comment["body"].getStr()]

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
  result = true
  if gConfig.noverify:
    return

  decho "Building testament"
  var
    cmd = gConfig.nim & " c --taintMode:on -d:nimCoroutines " &
      gConfig.nimdir/"tests"/"testament"/"tester"
    (output, error) = execCmdEx(cmd)

  if error != 0:
    echo output
    return false

proc testCategory(): bool =
  decho "Testing " & gConfig.category
  var
    cmd = gConfig.nimdir/"tests"/"testament"/"tester" &
      " \"--nim:" & "compiler"/"nim" & " \" cat " & gConfig.category
    error = 0

  decho cmd
  withDir gConfig.nimdir:
    error = execCmd(cmd)

  return error == 0

proc addTestcase(issueid, snippet, nimout: string): bool =
  result = true
  let
    fn = gConfig.nimdir/"tests"/gConfig.category/"t$#.nim" % issueid

  if fileExists(fn):
    if not gConfig.force:
      return false

  var errorStr = ""
  for line in nimout.splitLines():
    if line =~ peg"""'temp.nim'\({\d+}', '+\d+\)' Error: '{.+}""":
      errorStr = "discard \"\"\"\nerrormsg: \"$#\"\nline: $#\n\"\"\"\n\n" %
        [matches[1], $(parseInt(matches[0])+5)]
      break

  writeFile(fn, errorStr & snippet)

proc createBranch(issueid: string): bool =
  decho "Creating branch for " & issueid
  result = true
  let
    fn = "tests"/gConfig.category/"t$#.nim" % issueid

  var
    cmds = @[
      # Checkout devel
      "git checkout devel",

      # Update repo with upstream
      "git fetch upstream",
      "git merge upstream/devel",
      "git push",

      # Create branch
      "git branch test-" & issueid,
      "git checkout test-" & issueid,

      # Commit test case and push
      "git add " & fn,
      "git commit -m \"Test case for #$#\"" % issueid,
      "git push origin test-" & issueid,

      # Checkout devel
      "git checkout devel"
    ]
    error = 0

  withDir gConfig.nimdir:
    for cmd in cmds:
      echo cmd
      error = execCmd(cmd)
      if error != 0:
        return false

proc createPR(issueid: string): bool =
  decho "Creating PR for " & issueid
  result = true
  var
    cl = newHttpClient(proxy = getProxy())

  cl.headers = getAuth()

  var
    res = cl.getContent("https://api.github.com/user").parseJson()
    user = res["login"].getStr()
    body="""{"title": "Test case for #$1", "head": "$2:test-$1", "base": "devel"}""" % [issueid, user]
    pr = cl.request("https://api.github.com/repos/nim-lang/nim/pulls",
      httpMethod = HttpPost, body = body)

  if "201" notin pr.status:
    decho pr.body
    return false

proc checkIssue(issue: JsonNode, config: ConfigObj) {.gcsafe.} =
  gConfig = config
  if "number" notin issue:
    return

  if gConfig.noncrash or isCrash(issue):
    var
      comments: JsonNode
      crashtype = "NOSNIPT"
      nimout = ""
      nimoutlc = ""
      nimouttemp = ""
      output = " - Issue $#: $#" % [$issue["number"], ($issue["title"]).strip(chars={'"', ' '})]
      outverb = ""
      snippet = ""

    if gConfig.commno != 0 or gConfig.write:
      comments = getComments(issue["number"].getInt())

    if gConfig.commno != 0:
      snippet = getSnippet(comments[gConfig.commno-1])
    else:
      snippet = getSnippet(issue)

    if snippet != "":
      if gConfig.foreground:
        echo "-------- SNIPPET --------"
        echo snippet
        echo "-------------------------\n"

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
      writeFile("logs"/crashtype & "-" & $issue["number"] & ".txt",
        output & "\n\n" & outverb & "\n\n" & getIssueDiscussion(issue, comments))

    if gConfig.comment:
      commentIssue($issue["number"], getCommentOut(crashtype, outverb))

    if gConfig.category.len() != 0:
      if not addTestcase($issue["number"], snippet, nimout):
        echo "Test case already exists, use -F"
      elif not gConfig.noverify:
        if not testCategory():
          echo "Test verification failed"
          return

      if gConfig.pr:
        if not createBranch($issue["number"]):
          echo "Branch creation failed"
        elif not createPR($issue["number"]):
          echo "Failed to create PR"

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
    elif param[0..<2] == "-C":
      gConfig.commno = parseInt(param[2..^1])
      if gConfig.commno < 0:
        echo "Bad comment number"
        quit(1)
    elif param == "-d":
      gConfig.direction = "desc"
    elif param == "-e":
      gConfig.edit = true
      gConfig.foreground = true
    elif param == "-f":
      gConfig.foreground = true
    elif param == "-F":
      gConfig.force = true
    elif param == "-k":
      gConfig.noverify = true
    elif param[0..<2] == "-m":
      gConfig.mode = param[2..^1]
    elif param == "-n":
      gConfig.noncrash = true
    elif param == "-o":
      gConfig.write = true
    elif param == "-p":
      gConfig.pr = true
    elif param[0..<2] == "-s":
      gConfig.snipno = parseInt(param[2..^1])
      if gConfig.snipno < 1:
        echo "Bad snippet number"
        quit(1)
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
        quit(1)

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
