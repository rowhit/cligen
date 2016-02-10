## This is a more featureful API-compatibile replacement for stdlib's parseopt2.
## It works as the original advertises.  In addition, this version also provides
## flexibility over requiring separators between option keys & option values, as
## per traditional "Unix-like" command syntax.  This version also supports a set
## of "stop words" - special whole command parameters preventing any subsequent
## parameters being interpreted as options, basically words that work like "--".
## Such stop words can still be the arguments to any options - only unprefixed
## usage acts as a stop.  Supported command syntax is:
##
## 1. short options - ``-abcd``, where a, b, c, d are names in shortBools
##
## 1a. short opts with args ``-abc:Bar``, ``-abc=Bar``, ``-c Bar``, ``-abcBar``
##
## 2. long options - ``--foo:bar``, ``--foo=bar`` or ``--foo`` or ``--foo bar``
##
## 3. arguments - everything else/anything after "--" or a stopword.
##
## The key-value-separator-free forms above require appropriate shortBools and
## longBools lists for boolean flags.

import os, strutils

type
  CmdLineKind* = enum         ## the detected command line token
    cmdEnd,                   ## end of command line reached
    cmdArgument,              ## argument detected
    cmdLongOption,            ## a long option ``--option`` detected
    cmdShortOption            ## a short option ``-c`` detected
  OptParser* =
      object of RootObj       ## this object implements the command line parser
    cmd: seq[string]          # command line being parsed
    pos: int                  # current command parameter to inspect
    moreShort: string         # carry over short flags to process
    optsDone: bool            # "--" has been seen
    shortBools: string        # 1-letter options not requiring optarg
    longBools: seq[string]    # long options not requiring optarg
    stopWords: seq[string]    # special literal parameters that act like "--"
    requireSep: bool          # require separator between option key & val
    sepChars: set[char]
    kind*: CmdLineKind        ## the detected command line token
    key*, val*: TaintedString ## key and value pair; ``key`` is the option
                              ## or the argument, ``value`` is not "" if
                              ## the option was given a value

proc initOptParser*(cmdline: seq[string] = commandLineParams(),
                    shortBools: string = nil,
                    longBools: seq[string] = nil,
                    requireSeparator=false,  # true imitates stdlib parseopt2
                    sepChars: string= "=:",
                    stopWords: seq[string] = @[]): OptParser =
  ## Initializes option parses. `cmdline` should not contain parameter 0,
  ## typically the program name.  If `cmdline` is not given, default to program
  ## parameters. `shortBools` and `longBools` specify respectively one-letter
  ## and long option keys that do _not_ take arguments.  If `requireSeparator`
  ## is true, then option keys and values must be separated by an element of
  ## sepChars ("=" or ":" by default) in either short or long contexts.  If
  ## requireSeparator==false, the parser knows only non-bool option keys will
  ## expect args and users may say ``-aboVal`` or ``-o Val`` or ``--opt Val``
  ## [ as well as the ``-o=Val``|``--opt=Val`` style which always works ].
  ## Parameters following either "--" or any literal parameter in stopWords are
  ## never interpreted as options.
  result.cmd = @cmdline                 #XXX is @ necessary?  Does that copy?
  result.shortBools = shortBools
  result.longBools = longBools
  result.requireSep = requireSeparator
  for c in sepChars:
    result.sepChars.incl(c)
  result.stopWords = stopWords
  result.moreShort = ""
  result.optsDone = false

proc do_short(p: var OptParser) =
  p.kind = cmdShortOption
  p.val = nil
  p.key = p.moreShort[0..0]             # shift off first char as key
  p.moreShort = p.moreShort[1..^1]
  if p.moreShort.len == 0:              # param exhausted; advance param
    p.pos += 1
  if p.shortBools != nil and p.key in p.shortBools:     # no opt argument =>
    return                                              # continue w/same param
  if p.requireSep and p.moreShort[0] notin p.sepChars:  # No optarg in reqSep mode
    return
  if p.moreShort.len != 0:              # only advance if haven't already
    p.pos += 1
  if p.moreShort[0] in p.sepChars:      # shift off maybe-optional separator
    p.moreShort = p.moreShort[1..^1]
  if p.moreShort.len > 0:               # same param argument is trailing text
    p.val = p.moreShort
    p.moreShort = ""
    return
  if p.pos < p.cmd.len:                 # Empty moreShort; opt arg = next param
    p.val = p.cmd[p.pos]
    p.pos += 1
  elif p.shortBools != nil:
    echo "argument expected for option `", p.key, "` at end of params"

proc do_long(p: var OptParser) =
  p.kind = cmdLongOption
  p.val = nil
  let param = p.cmd[p.pos]
  p.pos += 1                            # always consume at least 1 param
  let sep = find(param, p.sepChars)     # only very first occurrence of delim
  if sep == 2:
    echo "Empty long option key at param", p.pos - 1, " (\"", param, "\")"
    p.key = nil
    return
  if sep > 2:
    p.key = param[2 .. sep-1]
    p.val = param[sep+1..^1]
    if p.longBools != nil and p.key in p.longBools:
      echo "Warning option `", p.key, "` does not expect an argument"
    return
  p.key = param[2..^1]                  # no sep; key is whole param past --
  if p.longBools != nil and p.key in p.longBools:
    return                              # No argument; done
  if p.requireSep:
    echo "Expecting option key-val separator :|= after `", p.key, "`"
    return
  if p.pos < p.cmd.len:                 # Take opt arg from next param
    p.val = p.cmd[p.pos]
    p.pos += 1
  elif p.longBools != nil:
    echo "argument expected for option `", p.key, "` at end of params"

proc next*(p: var OptParser) =
  if p.moreShort.len > 0:               #Step1: handle any remaining short opts
    do_short(p)
    return
  if p.pos >= p.cmd.len:                #Step2: end of params check
    p.kind = cmdEnd
    return
  if not p.cmd[p.pos].startsWith("-") or p.optsDone:  #Step3: non-option param
    p.kind = cmdArgument
    p.key = p.cmd[p.pos]
    p.val = nil
    if p.cmd[p.pos] in p.stopWords:     #Step4: check for stop word
      p.optsDone = true                 # should only hit Step3 henceforth
    p.pos += 1
    return
  if p.cmd[p.pos].startsWith("--"):     #Step5: "--*"
    if p.cmd[p.pos].len == 2:           # terminating "--" => pure arg mode
      p.optsDone = true                 # should only hit Step3 henceforth
      p.pos += 1                        # skip the "--" itself, unlike stopWords
      next(p)                           # do next one so each parent next()..
      return                            #..yields exactly 1 opt+arg|cmdarg
    do_long(p)
  else:                                 #Step6: "-" but not "--" => short opt
    if p.cmd[p.pos].len == 1:           #Step6a: simply "-" => non-option param
      p.kind = cmdArgument              #  {"-" often used to indicate "stdin"}
      p.key = p.cmd[p.pos]
      p.val = nil
      p.pos += 1
    else:                               #Step6b: maybe a block of short options
      p.moreShort = p.cmd[p.pos][1..^1] # slice out the initial "-"
      do_short(p)

type
  GetoptResult* = tuple[kind: CmdLineKind, key, val: TaintedString]

iterator getopt*(cmdline=commandLineParams(), shortBools: string = nil,
                 longBools: seq[string] = nil, requireSeparator=true,
                 sepChars="=:", stopWords: seq[string] = @[]): GetoptResult =
  var p = initOptParser(cmdline, shortBools, longBools, requireSeparator,
                        sepChars, stopWords)
  while true:
    next(p)
    if p.kind == cmdEnd: break
    yield (p.kind, p.key, p.val)
