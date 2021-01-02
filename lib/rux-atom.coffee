{CompositeDisposable, Disposable} = require 'atom'

contentCheckRegex = null
autoCompleteTagStartRegex = /(<)([a-zA-Z0-9\.:$_]+)/g
autoCompleteTagCloseRegex = /(<\/)([^>]+)(>)/g

ruxTagStartPattern = '(?x)((^|=|return)\\s*<([^!/?](?!.+?(</.+?>))))'
decreaseIndentForNextLinePattern = '(?x)
/>\\s*(,|;)?\\s*$
| ^(?!\\s*\\?)\\s*\\S+.*</[-_\\.A-Za-z0-9]+>$'

class RuxAtom
  config:
    disableAutoClose:
      type: 'boolean'
      default: false
      description: 'Disabled tag autocompletion'
    skipUndoStackForAutoCloseInsertion:
      type: 'boolean'
      default: true
      description: 'When enabled, auto insert/remove closing tag mutation is skipped from normal undo/redo operation'
    ruxTagStartPattern:
      type: 'string'
      default: ruxTagStartPattern
    decreaseIndentForNextLinePattern:
      type: 'string'
      default: decreaseIndentForNextLinePattern

  constructor: ->
  patchEditorLangModeAutoDecreaseIndentForBufferRow: (editor) ->
    self = this
    fn = editor.autoDecreaseIndentForBufferRow
    return if fn.ruxPatch

    # I don't understand what the frick this is trying to do (and it doesn't work),
    # so it's disabled in patchEditorLangMode below.
    editor.autoDecreaseIndentForBufferRow = (bufferRow, options) ->
      return fn.call(editor, bufferRow, options) unless editor.getGrammar().scopeName == "source.ruby.rux"

      scopeDescriptor = @scopeDescriptorForBufferPosition([bufferRow, 0])
      decreaseNextLineIndentRegex = @tokenizedBuffer.regexForPattern(atom.config.get('rux.decreaseIndentForNextLinePattern') || decreaseIndentForNextLinePattern)
      decreaseIndentRegex = @tokenizedBuffer.decreaseIndentRegexForScopeDescriptor(scopeDescriptor)
      increaseIndentRegex = @tokenizedBuffer.increaseIndentRegexForScopeDescriptor(scopeDescriptor)

      precedingRow = @tokenizedBuffer.buffer.previousNonBlankRow(bufferRow)

      return if precedingRow < 0

      precedingLine = @tokenizedBuffer.buffer.lineForRow(precedingRow)
      line = @tokenizedBuffer.buffer.lineForRow(bufferRow)

      if precedingLine and decreaseNextLineIndentRegex.testSync(precedingLine) and
         not (increaseIndentRegex and increaseIndentRegex.testSync(precedingLine)) and
         not @isBufferRowCommented(precedingRow)
        currentIndentLevel = @indentationForBufferRow(precedingRow)
        currentIndentLevel -= 1 if decreaseIndentRegex and decreaseIndentRegex.testSync(line)
        desiredIndentLevel = currentIndentLevel - 1
        if desiredIndentLevel >= 0 and desiredIndentLevel < currentIndentLevel
          @setIndentationForBufferRow(bufferRow, desiredIndentLevel)
      else if not @isBufferRowCommented(bufferRow)
        fn.call(editor, bufferRow, options)

  patchEditorLangModeSuggestedIndentForBufferRow: (editor) ->
    self = this
    fn = editor.suggestedIndentForBufferRow
    return if fn.ruxPatch

    editor.suggestedIndentForBufferRow = (bufferRow, options) ->
      indent = fn.call(editor, bufferRow, options)
      return indent unless editor.getGrammar().scopeName == "source.ruby.rux" and bufferRow > 1

      scopeDescriptor = @scopeDescriptorForBufferPosition([bufferRow, 0])

      decreaseNextLineIndentRegex = @tokenizedBuffer.regexForPattern(atom.config.get('rux.decreaseIndentForNextLinePattern') || decreaseIndentForNextLinePattern)
      decreaseIndentRegex = @tokenizedBuffer.decreaseIndentRegexForScopeDescriptor(scopeDescriptor)
      tagStartRegex = @tokenizedBuffer.regexForPattern(atom.config.get('rux.ruxTagStartPattern') || ruxTagStartPattern)

      precedingRow = @tokenizedBuffer.buffer.previousNonBlankRow(bufferRow)

      return indent if precedingRow < 0

      precedingLine = @tokenizedBuffer.buffer.lineForRow(precedingRow)

      return indent if not precedingLine?

      if @isBufferRowCommented(bufferRow) and @isBufferRowCommented(precedingRow)
        return @indentationForBufferRow(precedingRow)

      tagStartTest = tagStartRegex.testSync(precedingLine)
      decreaseIndentTest = decreaseIndentRegex.testSync(precedingLine)

      indent += 1 if tagStartTest and not @isBufferRowCommented(precedingRow)
      indent -= 1 if precedingLine and not decreaseIndentTest and decreaseNextLineIndentRegex.testSync(precedingLine) and not @isBufferRowCommented(precedingRow)

      return Math.max(indent, 0)

  patchEditorLangMode: (editor) ->
    @patchEditorLangModeSuggestedIndentForBufferRow(editor)?.ruxPatch = true
    # @patchEditorLangModeAutoDecreaseIndentForBufferRow(editor)?.ruxPatch = true

  isRuxEnabledForEditor: (editor) ->
    return editor? && editor.getGrammar().scopeName in ["source.ruby.rux"]

  autoSetGrammar: (editor) ->
    return if @isRuxEnabledForEditor editor

    path = require 'path'

    # Check if file extension is .rux
    extName = path.extname(editor.getPath() or '')
    if extName is ".rux"
      ruxGrammar = atom.grammars.grammarForScopeName("source.ruby.rux")
      editor.setGrammar ruxGrammar if ruxGrammar

  autoCloseTag: (eventObj, editor) ->
    return if atom.config.get('rux.disableAutoClose')

    return if not @isRuxEnabledForEditor(editor) or editor != atom.workspace.getActiveTextEditor()

    if eventObj?.newText is '>' and !eventObj.oldText
      # auto closing multiple cursors is a little bit tricky so lets disable it for now
      return if editor.getCursorBufferPositions().length > 1;

      tokenizedLine = editor.tokenizedBuffer?.tokenizedLineForRow(eventObj.newRange.end.row)
      return if not tokenizedLine?

      token = tokenizedLine.tokenAtBufferColumn(eventObj.newRange.end.column - 1)

      if not token? or token.scopes.indexOf('tag.open.ruby') == -1 or token.scopes.indexOf('punctuation.definition.tag.end.ruby') == -1
        return

      lines = editor.buffer.getLines()
      row = eventObj.newRange.end.row
      line = lines[row]
      line = line.substr 0, eventObj.newRange.end.column

      # Tag is self closing
      return if line.substr(line.length - 2, 1) is '/'

      tagName = null

      while line? and not tagName?
        match = line.match autoCompleteTagStartRegex
        if match? && match.length > 0
          tagName = match.pop().substr(1)
        row--
        line = lines[row]

      if tagName?
        if atom.config.get('rux.skipUndoStackForAutoCloseInsertion')
          options = {undo: 'skip'}
        else
          options = {}

        editor.insertText('</' + tagName + '>', options)
        editor.setCursorBufferPosition(eventObj.newRange.end)

    else if eventObj?.oldText is '>' and eventObj?.newText is ''

      lines = editor.buffer.getLines()
      row = eventObj.newRange.end.row
      fullLine = lines[row]

      tokenizedLine = editor.tokenizedBuffer?.tokenizedLineForRow(eventObj.newRange.end.row)
      return if not tokenizedLine?

      token = tokenizedLine.tokenAtBufferColumn(eventObj.newRange.end.column - 1)
      if not token? or token.scopes.indexOf('tag.open.ruby') == -1
        return
      line = fullLine.substr 0, eventObj.newRange.end.column

      # Tag is self closing
      return if line.substr(line.length - 1, 1) is '/'

      tagName = null

      while line? and not tagName?
        match = line.match autoCompleteTagStartRegex
        if match? && match.length > 0
          tagName = match.pop().substr(1)
        row--
        line = lines[row]

      if tagName?
        rest = fullLine.substr(eventObj.newRange.end.column)
        if rest.indexOf('</' + tagName + '>') == 0
          # rest is closing tag
          if atom.config.get('rux.skipUndoStackForAutoCloseInsertion')
            options = {undo: 'skip'}
          else
            options = {}
          serializedEndPoint = [eventObj.newRange.end.row, eventObj.newRange.end.column];
          editor.setTextInBufferRange(
            [
              serializedEndPoint,
              [serializedEndPoint[0], serializedEndPoint[1] + tagName.length + 3]
            ]
          , '', options)

    else if eventObj? and eventObj.newText.match /\r?\n/
      lines = editor.buffer.getLines()
      row = eventObj.newRange.end.row
      lastLine = lines[row - 1]
      fullLine = lines[row]

      if />$/.test(lastLine) and fullLine.search(autoCompleteTagCloseRegex) == 0
        while lastLine?
          match = lastLine.match autoCompleteTagStartRegex
          if match? && match.length > 0
            break
          row--
          lastLine = lines[row]

        lastLineSpaces = lastLine.match(/^\s*/)
        lastLineSpaces = if lastLineSpaces? then lastLineSpaces[0] else ''
        editor.insertText('\n' + lastLineSpaces)
        editor.setCursorBufferPosition(eventObj.newRange.end)

  processEditor: (editor) ->
    @patchEditorLangMode(editor)
    @autoSetGrammar(editor)
    disposableBufferEvent = editor.buffer.onDidChange (e) =>
                        @autoCloseTag e, editor

    @disposables.add editor.onDidDestroy => disposableBufferEvent.dispose()

    @disposables.add(disposableBufferEvent);

  deactivate: ->
    @disposables.dispose()

  activate: ->
    @disposables = new CompositeDisposable();

    # Bind events
    disposableProcessEditor = atom.workspace.observeTextEditors @processEditor.bind(this)
    @disposables.add disposableProcessEditor


module.exports = RuxAtom
