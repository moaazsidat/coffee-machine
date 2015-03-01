(->
  StateMachine =
    
    #---------------------------------------------------------------------------
    VERSION: "2.3.5"
    
    #---------------------------------------------------------------------------
    Result:
      SUCCEEDED: 1 # the event transitioned successfully from one state to another
      NOTRANSITION: 2 # the event was successfull but no state transition was necessary
      CANCELLED: 3 # the event was cancelled by the caller in a beforeEvent callback
      PENDING: 4 # the event is asynchronous and the caller is in control of when the transition occurs

    Error:
      INVALID_TRANSITION: 100 # caller tried to fire an event that was innapropriate in the current state
      PENDING_TRANSITION: 200 # caller tried to fire an event while an async transition was still pending
      INVALID_CALLBACK: 300 # caller provided callback function threw an exception

    WILDCARD: "*"
    ASYNC: "async"
    
    #---------------------------------------------------------------------------
    create: (cfg, target) ->
      initial = (if (typeof cfg.initial is "string") then state: cfg.initial else cfg.initial) # allow for a simple string, or an object with { state: 'foo', event: 'setup', defer: true|false }
      terminal = cfg.terminal or cfg["final"]
      fsm = target or cfg.target or {}
      events = cfg.events or []
      callbacks = cfg.callbacks or {}
      map = {} # track state transitions allowed for an event { event: { from: [ to ] } }
      transitions = {} # track events allowed from a state            { state: [ event ] }
      add = (e) ->
        from = (if (e.from instanceof Array) then e.from else ((if e.from then [ e.from ] else [ StateMachine.WILDCARD ]))) # allow 'wildcard' transition if 'from' is not specified
        map[e.name] = map[e.name] or {}
        

        for f in from
          transitions[f] = transitions[f] or []
          transitions[f].push e.name
          map[e.name][f] = e.to or f # allow no-op transition if 'to' is not specified
          

      if initial
        initial.event = initial.event or "startup"
        add
          name: initial.event
          from: "none"
          to: initial.state

      

      for event in events
        add event
      for name of map
        fsm[name] = StateMachine.buildEvent(name, map[name])  if map.hasOwnProperty(name)
      for name of callbacks
        fsm[name] = callbacks[name]  if callbacks.hasOwnProperty(name)
      fsm.current = "none"
      fsm.is = (state) ->
        (if (state instanceof Array) then (state.indexOf(@current) >= 0) else (@current is state))

      fsm.can = (event) ->
        not @transition and (map[event].hasOwnProperty(@current) or map[event].hasOwnProperty(StateMachine.WILDCARD))

      fsm.cannot = (event) ->
        not @can(event)

      fsm.transitions = ->
        transitions[@current]

      fsm.isFinished = ->
        @is terminal

      fsm.error = cfg.error or (name, from, to, args, error, msg, e) -> # default behavior when something unexpected happens is to throw an exception, but caller can override this behavior if desired (see github issue #3 and #17)
        throw e or msg

      fsm[initial.event]()  if initial and not initial.defer
      fsm

    
    #===========================================================================
    doCallback: (fsm, func, name, from, to, args) ->
      if func
        try
          return func.apply(fsm, [ name, from, to ].concat(args))
        catch e
          return fsm.error(name, from, to, args, StateMachine.Error.INVALID_CALLBACK, "an exception occurred in a caller-provided callback function", e)

    beforeAnyEvent: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onbeforeevent"], name, from, to, args

    afterAnyEvent: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onafterevent"] or fsm["onevent"], name, from, to, args

    leaveAnyState: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onleavestate"], name, from, to, args

    enterAnyState: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onenterstate"] or fsm["onstate"], name, from, to, args

    changeState: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onchangestate"], name, from, to, args

    beforeThisEvent: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onbefore" + name], name, from, to, args

    afterThisEvent: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onafter" + name] or fsm["on" + name], name, from, to, args

    leaveThisState: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onleave" + from], name, from, to, args

    enterThisState: (fsm, name, from, to, args) ->
      StateMachine.doCallback fsm, fsm["onenter" + to] or fsm["on" + to], name, from, to, args

    beforeEvent: (fsm, name, from, to, args) ->
      false  if (false is StateMachine.beforeThisEvent(fsm, name, from, to, args)) or (false is StateMachine.beforeAnyEvent(fsm, name, from, to, args))

    afterEvent: (fsm, name, from, to, args) ->
      StateMachine.afterThisEvent fsm, name, from, to, args
      StateMachine.afterAnyEvent fsm, name, from, to, args

    leaveState: (fsm, name, from, to, args) ->
      specific = StateMachine.leaveThisState(fsm, name, from, to, args)
      general = StateMachine.leaveAnyState(fsm, name, from, to, args)
      if (false is specific) or (false is general)
        false
      else StateMachine.ASYNC  if (StateMachine.ASYNC is specific) or (StateMachine.ASYNC is general)

    enterState: (fsm, name, from, to, args) ->
      StateMachine.enterThisState fsm, name, from, to, args
      StateMachine.enterAnyState fsm, name, from, to, args

    
    #===========================================================================
    buildEvent: (name, map) ->
      ->
        from = @current
        to = map[from] or map[StateMachine.WILDCARD] or from
        args = Array::slice.call(arguments) # turn arguments into pure array
        return @error(name, from, to, args, StateMachine.Error.PENDING_TRANSITION, "event " + name + " inappropriate because previous transition did not complete")  if @transition
        return @error(name, from, to, args, StateMachine.Error.INVALID_TRANSITION, "event " + name + " inappropriate in current state " + @current)  if @cannot(name)
        return StateMachine.Result.CANCELLED  if false is StateMachine.beforeEvent(this, name, from, to, args)
        if from is to
          StateMachine.afterEvent this, name, from, to, args
          return StateMachine.Result.NOTRANSITION
        
        # prepare a transition method for use EITHER lower down, or by caller if they want an async transition (indicated by an ASYNC return value from leaveState)
        fsm = this
        @transition = ->
          fsm.transition = null # this method should only ever be called once
          fsm.current = to
          StateMachine.enterState fsm, name, from, to, args
          StateMachine.changeState fsm, name, from, to, args
          StateMachine.afterEvent fsm, name, from, to, args
          StateMachine.Result.SUCCEEDED

        @transition.cancel = -> # provide a way for caller to cancel async transition if desired (issue #22)
          fsm.transition = null
          StateMachine.afterEvent fsm, name, from, to, args

        leave = StateMachine.leaveState(this, name, from, to, args)
        if false is leave
          @transition = null
          StateMachine.Result.CANCELLED
        else if StateMachine.ASYNC is leave
          StateMachine.Result.PENDING
        else
          # need to check in case user manually called transition() but forgot to return StateMachine.ASYNC
          @transition()  if @transition

  # StateMachine
  
  #===========================================================================
  
  #======
  # NODE
  #======
  if typeof exports isnt "undefined"
    exports = module.exports = StateMachine  if typeof module isnt "undefined" and module.exports
    exports.StateMachine = StateMachine
  
  #============
  # AMD/REQUIRE
  #============
  else if typeof define is "function" and define.amd
    define (require) ->
      StateMachine

  
  #========
  # BROWSER
  #========
  else if typeof window isnt "undefined"
    window.StateMachine = StateMachine
  
  #===========
  # WEB WORKER
  #===========
  else self.StateMachine = StateMachine  if typeof self isnt "undefined"
)()