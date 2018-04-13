```
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
  -h
```
