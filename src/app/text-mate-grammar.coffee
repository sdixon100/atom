_ = require 'underscore'
fs = require 'fs'
plist = require 'plist'

module.exports =
class TextMateGrammar
  @loadFromPath: (path) ->
    grammar = null
    plist.parseString fs.read(path), (e, data) ->
      throw new Error(e) if e
      grammar = new TextMateGrammar(data[0])
    grammar

  name: null
  fileTypes: null
  foldEndRegex: null
  repository: null
  initialRule: null

  constructor: ({ @name, @fileTypes, scopeName, patterns, repository, foldingStopMarker}) ->
    @initialRule = new Rule(this, {scopeName, patterns})
    @repository = {}
    @foldEndRegex = new OnigRegExp(foldingStopMarker) if foldingStopMarker

    for name, data of repository
      @repository[name] = new Rule(this, data)

  getLineTokens: (line, stack=[@initialRule]) ->
    stack = new Array(stack...)
    tokens = []
    position = 0

    loop
      scopes = scopesFromStack(stack)

      if line.length == 0
        tokens = [{value: "", scopes: scopes}]
        return { tokens, scopes }

      break if position == line.length

      { nextTokens, tokensStartPosition, tokensEndPosition} = _.last(stack).getNextTokens(stack, line, position)

      if nextTokens
        if position < tokensStartPosition # unmatched text preceding next tokens
          tokens.push
            value: line[position...tokensStartPosition]
            scopes: scopes

        tokens.push(nextTokens...)
        position = tokensEndPosition
      else if tokensEndPosition - tokensStartPosition != 0 # break unless it was a zero length match
        tokens.push
          value: line[position...line.length]
          scopes: scopes
        break

    { tokens, stack }

  ruleForInclude: (name) ->
    if name[0] == "#"
      @repository[name[1..]]
    else if name == "$self"
      @initialRule

class Rule
  grammar: null
  scopeName: null
  patterns: null
  createEndPattern: null

  constructor: (@grammar, {@scopeName, patterns, @endPattern}) ->
    patterns ?= []
    @patterns = patterns.map (pattern) => new Pattern(grammar, pattern)
    @patterns.unshift(@endPattern) if @endPattern and !@endPattern.hasBackReferences

  getIncludedPatterns: (included=[]) ->
    return [] if _.include(included, this)

    return @allPatterns if @allPatterns

    included = included.concat([this])
    @allPatterns = []
    for pattern in @patterns
      @allPatterns.push(pattern.getIncludedPatterns(included)...)
    @allPatterns

  getScanner: ->
    @scanner ?= new OnigScanner(_.pluck(@getIncludedPatterns(), 'regexSource'))

  getNextTokens: (stack, line, position) ->
    patterns = @getIncludedPatterns()

    return {} unless result = @getScanner().findNextMatch(line, position)
    { index, captureIndices } = result

    [firstCaptureIndex, firstCaptureStart, firstCaptureEnd] = captureIndices
    nextTokens = patterns[index].handleMatch(stack, line, captureIndices)
    { nextTokens, tokensStartPosition: firstCaptureStart, tokensEndPosition: firstCaptureEnd }

  getRuleToPush: (line, beginPatternCaptureIndices) ->
    if @endPattern.hasBackReferences
      rule = new Rule(@grammar, {@scopeName})
      rule.endPattern = @endPattern.resolveBackReferences(line, beginPatternCaptureIndices)
      rule.patterns = [rule.endPattern, @patterns...]
      rule
    else
      this

class Pattern
  grammar: null
  pushRule: null
  popRule: false
  scopeName: null
  regex: null
  captures: null
  backReferences: null

  constructor: (@grammar, { name, contentName, @include, match, begin, end, captures, beginCaptures, endCaptures, patterns, @popRule, hasBackReferences}) ->
    @scopeName = name ? contentName # TODO: We need special treatment of contentName
    if match
      if @hasBackReferences = hasBackReferences ? /\\\d+/.test(match)
        @match = match
      else
        @regex = new OnigRegExp(match)
        @regexSource = match
      @captures = captures
    else if begin
      @regex = new OnigRegExp(begin)
      @regexSource = begin
      @captures = beginCaptures ? captures
      endPattern = new Pattern(@grammar, { match: end, captures: endCaptures ? captures, popRule: true})
      @pushRule = new Rule(@grammar, { @scopeName, patterns, endPattern })

  resolveBackReferences: (line, beginCaptureIndices) ->
    beginCaptures = []

    for i in [0...beginCaptureIndices.length] by 3
      start = beginCaptureIndices[i + 1]
      end = beginCaptureIndices[i + 2]
      beginCaptures.push line[start...end]

    resolvedMatch = @match.replace /\\\d+/g, (match) ->
      index = parseInt(match[1..])
      _.escapeRegExp(beginCaptures[index] ? "\\#{index}")

    new Pattern(@grammar, { hasBackReferences: false, match: resolvedMatch, @captures, @popRule })

  getIncludedPatterns: (included) ->
    if @include
      rule = @grammar.ruleForInclude(@include)
      # console.log "Could not find rule for include #{@include} in #{@grammar.name} grammar" unless rule
      rule?.getIncludedPatterns(included) ? []
    else
      [this]

  handleMatch: (stack, line, captureIndices) ->
    scopes = scopesFromStack(stack)
    scopes.push(@scopeName) if @scopeName and not @popRule

    if @captures
      tokens = @getTokensForCaptureIndices(line, _.clone(captureIndices), scopes)
    else
      [start, end] = captureIndices[1..2]
      zeroLengthMatch = end == start
      if zeroLengthMatch
        tokens = null
      else
        tokens = [{ value: line[start...end], scopes: scopes }]
    if @pushRule
      stack.push(@pushRule.getRuleToPush(line, captureIndices))
    else if @popRule
      stack.pop()

    tokens

  getTokensForCaptureIndices: (line, captureIndices, scopes) ->
    [parentCaptureIndex, parentCaptureStart, parentCaptureEnd] = shiftCapture(captureIndices)

    tokens = []
    if scope = @captures[parentCaptureIndex]?.name
      scopes = scopes.concat(scope)

    previousChildCaptureEnd = parentCaptureStart
    while captureIndices.length and captureIndices[1] < parentCaptureEnd
      [childCaptureIndex, childCaptureStart, childCaptureEnd] = captureIndices

      emptyCapture = childCaptureEnd - childCaptureStart == 0
      captureHasNoScope = not @captures[childCaptureIndex]
      if emptyCapture or captureHasNoScope
        shiftCapture(captureIndices)
        continue

      if childCaptureStart > previousChildCaptureEnd
        tokens.push
          value: line[previousChildCaptureEnd...childCaptureStart]
          scopes: scopes

      captureTokens = @getTokensForCaptureIndices(line, captureIndices, scopes)
      tokens.push(captureTokens...)
      previousChildCaptureEnd = childCaptureEnd

    if parentCaptureEnd > previousChildCaptureEnd
      tokens.push
        value: line[previousChildCaptureEnd...parentCaptureEnd]
        scopes: scopes

    tokens

shiftCapture = (captureIndices) ->
  [captureIndices.shift(), captureIndices.shift(), captureIndices.shift()]

scopesFromStack = (stack) ->
  _.compact(_.pluck(stack, "scopeName"))

