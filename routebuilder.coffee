Q              = require 'q'
_              = require 'underscore'
path           = require 'path'
fs             = require 'fs'

FN_ARGS        = /^function\s*[^\(]*\(\s*([^\)]*)\)/m
FN_ARG_SPLIT   = /\s*,\s*/
STRIP_COMMENTS = /((\/\/.*$)|(\/\*[\s\S]*?\*\/))/mg
REQUEST_PARAMS =
  body     : true
  query    : true
  url      : true
  headers  : true
  params   : true
  files    : true
  cookies  : true
  protocol : true
  url      : true

SERIALIZERS =
  html :
    success : (req, res, result) ->
      res.send(result)
    fail    : (req, res, err) ->
      console.log err.stack
      res.send 500, err.message
  json :
    success : (req, res, result) ->
      res.json
        status : 'success'
        data   : result
    fail : (req, res, err) ->
      console.log err.stack
      res.json
        status : 'error',
        data   : err.message
  file : 
    success : (req, res, result) ->
      fileName = ''
      filePath = ''
      fileType = 'application/octet-stream'

      if typeof result == 'object'
        filePath = result.path
        fileName = result.name || path.basename filePath
        fileType = result.type if result.type
      else
        filePath = result
        fileName = path.basename filePath

      res.setHeader('Content-disposition', "attachment; filename=#{fileName}")
      res.setHeader('Content-Type', fileType) if fileType

      filestream = fs.createReadStream(filePath)
      filestream.pipe(res)
    fail : (req, res, err) ->
      console.log err.stack
      res.send 500, 'file not found'

initializeController = (app, routes, controllerName) ->
  controller   = require(controllerName)
  [dependencies, injectors, serializers] = loadConfig controller

  for routeName, controllerAction of routes
    [method, url] = controllerAction.split /\s+/, 2
    routeConfig   = controller.requests[routeName]
    middleware    = [
      url,
      (req, res, next) ->
        req.$scope = {}
        next()
    ]

    unless routeConfig
      throw new Error("Missing controller action '#{controllerAction}' on controller '#{controllerName}' for route '#{routeName}'")
    
    lastHandler = routeConfig[routeConfig.length - 1]
    lastKey     = ''

    # get the last handler from the routeConfig
    if typeof lastHandler == 'object'
      keys        = Object.keys(lastHandler)
      lastKey     = keys.pop()
      object      = lastHandler
      lastHandler = object[lastKey]
      delete object[lastKey]
    else
      routeConfig.pop()

    for handlers, index in routeConfig
      if typeof handlers == 'object'
        for handlerName, handler of handlers
          middleware.push injectedMiddleware(handler, handlerName, dependencies, injectors)
      else
        middleware.push injectedMiddleware(handlers, '', dependencies, injectors)

    middleware.push injectedMiddleware(lastHandler, lastKey, dependencies, injectors, serializers)

    app[method].apply app, middleware

loadConfig = (controller) ->
  results = []
  config  = if controller.config then require controller.config else {}

  for option in ['dependencies', 'injectors', 'serializers']
    list = _.extend({}, config[option] || {}, controller[option] || {})
    if option == 'dependencies'
      results.push loadDependencies(list)
    else if option == 'injectors'
      results.push loadInjectors(list)
    else if option == 'serializers'
      results.push loadSerializers(list)

  return results

loadDependencies = (dependenciesList) ->
  dependencies = {}

  for name, dependency of dependenciesList
    if typeof dependency == 'string'
      dependencies[name] = require dependency
    else if typeof dependency == 'object' && dependency.path?
      dependencies[name] = require dependency.path
      dependencies[name] = dependency.filter(dependencies[name]) if dependency.filter
    else
      dependencies[name] = dependency

  return dependencies

loadInjectors = (injectorsList) ->
  injectors = {}

  for name, fn of injectorsList
    injectors[name] =
      args     : getArgs(fn)
      fn       : fn

  return injectors

loadSerializers = (serializersList) ->
  serializers = clone SERIALIZERS

  for name, serializer of serializersList
    type = typeof serializer
    if type == 'function'
      serializers[name].fail    = serializer
      serializers[name].success = (req, res, result) ->
        serializer.call {}, req, res, null, result
    else if type == 'object'
      serializers[name].fail    = serializer.fail    if serializer.fail
      serializers[name].success = serializer.success if serializer.success
    else
      throw new Error("unsuppored serializer type, expected function or object and received #{type}")

  return serializers

clone = (obj) ->
  if not obj? or typeof obj isnt 'object'
    return obj

  newInstance = {}

  for key of obj
    newInstance[key] = clone obj[key]

  return newInstance


injectedMiddleware = (fn, fnName, dependencies, injectors, serializers) ->
  unless typeof fn == 'function'
    throw new Error('unsupported handler type, expected object or function and received "' + typeof fn + '"')

  store    = fnName.match(/^\$.*/)
  argNames = getArgs fn
  
  if serializers
    return (req, res) ->
      callWithInjectedArgs(fn, {}, argNames, req, dependencies, injectors)
        .then (result) ->
          fnName = fnName || 'json'
          if serializers?[fnName]?.success
            return serializers[fnName].success(req, res, result)

          throw new Error("Could not find a success serializer for '#{fnName}'")
        .fail (error) ->
          if serializers?[fnName]?.fail
            return serializers[fnName].fail(req, res, error)

          throw new Error("Could not find a fail serializer for '#{fnName}'")

  else
    return (req, res, next) ->
      callWithInjectedArgs(fn, {}, argNames, req, dependencies, injectors)
        .then (result) ->
          req.$scope[fnName] = result if store
          next()
        .fail (error) ->
          next error

getArgs = (fn) ->
  fnStr = fn.toString().replace(STRIP_COMMENTS, "")
  args = fnStr.match(FN_ARGS)[1].split(FN_ARG_SPLIT)
  (if args.length is 1 and args[0] is "" then [] else args)

callWithInjectedArgs = (fn, scope, argNames, req, dependencies, injectors) ->
  injectedArgs = argNames.map (arg) ->
    arg = arg.substr(1) # strip off the leading $

    if req.$scope?["$#{arg}"]
      return req.$scope["$#{arg}"]
    else if REQUEST_PARAMS[arg]
      return req[arg]
    else if injectors[arg]
      return callWithInjectedArgs(
        injectors[arg].fn, {}, injectors[arg].args,
        req, dependencies, injectors
      )
    else if dependencies[arg]
      return dependencies[arg]
    else
      return require(arg)

  if not injectedArgs.length
    Q().then () -> fn.call(scope) 
  else
    Q.all(injectedArgs)
      .then (resolvedArgs) -> fn.apply(scope, resolvedArgs)

module.exports = (app, routeMap, routePath) ->
  for controllerName, routes of routeMap
    initializeController app, routes, "#{routePath}#{controllerName}"
