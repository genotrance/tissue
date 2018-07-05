Tissue is an automation tool to help debug Nim issues. It can test snippets
posted in Nim issues and comments on Github and speed up the fixing process.

# Installation

- Install Nim
- Build temporary compiler `nim_temp` if working on compiler issues

```
cd path/to/nimdir
koch temp
```

- Install tissue

```
nimble install tissue

  OR

git clone https://github.com/genotrance/tissue
cd tissue
nimble install -y
```

- Setup tissue configuration file with `nimdir` and any default preferred flags.

# Examples

```
tissue
```
Search all open Nim issues for crash reports, download associated code snippets,
run with `nim` in path and print brief results

```
tissue -v -o 1234
```
Run only on issue 1234 and generate verbose output to stdout and `logs/1234.txt`
including issue details and comments in the generated log file

```
tissue ../nimdevel
```
Use `../nimdevel/bin/nim` and `../nimdevel/bin/nim_temp` for test and to create
and submit test cases. This is especially useful if using choosenim since `nim_temp`
isn't in the path

```
tissue -pf5 -pl6 -o
```
Run tests on only the 5th page of issues on Github where each page contains 100
issues. Use `-pnX` to change page size

```
tissue -aerrmsgs 1234 ../nimdevel
```
Create a test case in `../nimdevel/tests/errmsgs/t1234.nim` with snippet loaded
from Github issue (including any error detection) and run with `testament` to
verify that test passes

```
tissue -e 1234
```
Run in interactive mode - wait before running `nim` so that snippet or `nim` can
be edited prior to test. Allow reruns until told to quit. Helpful to debug the
snippet or `nim` code until it works

```
tissue -n 1234 -s2
```
Run on second snippet for issue 1234 and ignore checks for crash reports

```
tissue -c 1234 ~/.nimble/github_api_token
```
Post a comment on Github with run details. Requires `tokenfile` to authenticate

```
tissue -C2 1234 -mjs
```
Run test on snippet in the second issue comment and run in Javascript mode

# Usage

```
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
```

# Config file

Create a `ti.cfg` file in the same directory as `tissue` or in the working dir
to save some keystrokes. CLI always overrides cfg file.

```
[config]
nimdir = "path/to/nim/dir"
tokenfile = "path/to/auth/token/file"
descending = true
edit = true
foreground = true
force = true
noncrash = true
verbose = true
write = true

[ignore]
issueid1
issueid2
...
```
