# Package

version       = "0.1.0"
author        = "genotrance"
description   = "Test failing snippets from Nim's issues"
license       = "MIT"

skipDirs = @["tests"]

# Dependencies

requires "nim >= 0.18.1"

bin = @["tissue"]
