# Package

version       = "0.1.6"
author        = "flywind"
description   = "A file system monitor in Nim."
license       = "Apache-2.0"
srcDir        = "src"


# Dependencies

requires "nim >= 1.6.0"

task tests, "Run all tests":
  exec "testament all"
