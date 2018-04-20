```
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
```
