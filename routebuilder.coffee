Q              = require 'q'
_              = require 'underscore'
FN_ARGS        = /^function\s*[^\(]*\(\s*([^\)]*)\)/m
FN_ARG_SPLIT   = /\s*,\s*/
STRIP_COMMENTS = /((\/\/.*$)|(\/\*[\s\S]*?\*\/))/mg
REQUEST_PARAMS =
    body    : true
    query   : true
    url     : true
    headers : true

SERIALIZERS =
    json : (req, res, result) ->
        res.json(result)
    file : (req, res, result) ->
        res.send('here rake nod some file contents! (not really)')

initializeController = (app, routes, controllerName) ->
    controller   = require(controllerName)
    [dependencies, injectors] = loadConfig controller

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

        middleware.push injectedMiddleware(lastHandler, lastKey, dependencies, injectors, true)

        app[method].apply app, middleware

loadConfig = (controller) ->
    return unless controller.config

    config = require controller.config

    dependenciesList = {}
    injectorsList    = {}

    _.extend(dependenciesList, config.dependencies || {}, controller.dependencies || {})
    _.extend(injectorsList, config.injectors || {}, controller.injectors || {})

    dependencies = loadDependencies dependenciesList
    injectors    = loadInjectors injectorsList

    return [dependencies, injectors]

loadDependencies = (dependenciesList) ->
    dependencies = {};

    for name, dependency of dependenciesList
        if typeof dependency == 'string'
            dependencies[name] = require dependency
        else
            dependencies[name] = require dependency.path
            dependencies[name] = dependency.filter(dependencies[name]) if dependency.filter

    return dependencies;

loadInjectors = (injectorsList) ->
    injectors = {};

    for name, fn of injectorsList
        injectors[name] =
            args : getArgs(fn),
            fn   : fn

    return injectors;

injectedMiddleware = (fn, fnName, dependencies, injectors, isLast = false) ->
    unless typeof fn == 'function'
        throw new Error('unsupported handler type, expected object or function and received "' + typeof fn + '"');

    store    = fnName.match(/^\$.*/)
    argNames = getArgs fn
    
    if isLast
        return (req, res) ->
            callWithInjectedArgs(fn, {}, argNames, req, dependencies, injectors)
                .then (result) ->
                    fnName = fnName || 'json'
                    return SERIALIZERS[fnName](req, res, result) if SERIALIZERS[fnName]
                    throw new Error("Could not find a serializer for '#{fnName}'")
                .fail (error) ->
                    throw error

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
        arg = arg.substr(1); # strip off the leading $

        if REQUEST_PARAMS[arg]
            return req[arg]
        else if req.$scope && req.$scope["$#{arg}"]
            return req.$scope["$#{arg}"]
        else if injectors && injectors[arg]
            return callWithInjectedArgs(
                injectors[arg].fn, {}, injectors[arg].args,
                req, dependencies, injectors
            )
        else if dependencies && dependencies[arg]
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
