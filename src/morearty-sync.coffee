_ = require 'lodash'
B = require 'backbone'
Imm = require 'immutable'
Morearty = require 'morearty'
{Binding, History} = Morearty
linkBinding = Morearty.Callback.set

defaultSync = B.sync

statusMap =
  'create': 'creating'
  'update': 'updating'
  'patch' : 'patching'
  'delete': 'deleting'
  'read'  : 'reading'

B.sync = (method, model, @options = {}) ->
  xhr = defaultSync method, model, options

  if model instanceof SyncModel
    model.setStatus 'xhr', statusMap[method]
    xhr
      .success ->
        # model.setStatus 'saved', true
        model.unsetStatus 'error'
      .fail (e, error, errorMessage) ->
        # TODO: merge previous state instead of undo, 'status' and 'error' make binding dirty
        model.history?.undo() if options.rollback
        model.setStatus 'error', Imm.fromJS(errorMessage || 'Unknown error')

      .always -> model.unsetStatus 'xhr'


validateModel = (ModelOrCollectionClass, BaseClass, type) ->
  if ModelOrCollectionClass != BaseClass
    if !(ModelOrCollectionClass.prototype instanceof BaseClass)
      throw new Error "#{type} should be instance of #{BaseClass.name}"



class SyncModel extends B.Model
  ###
  @param {Binding|Object} data - representing the model data. For raw object new binding will be created.
  ###
  constructor: (data, options = {}) ->
    defaults = trackStatus: true
    @options = _.extend defaults, options

    @binding =
      if data instanceof Binding
        data
      else
        # TODO: For now new binding is created if model is new. In this case binding
        # should be pointed to Vector entry when model data goes to collection.
        # The main question is: leave it as is or do not create own binding
        # for empty model and then strictly bind it to main state?
        data = @parse(data, @options) || {} if @options.parse
        Binding.init Imm.fromJS(data)

    @modelStatusBinding = @binding.sub '__model_status'

    # TODO: rewrite Morearty.History class
    @_historyBinding = Binding.init()
    @history = History.init @binding, @_historyBinding

    Object.defineProperties @,
      'id':
        writeable: false
        get: ->
          @get @idAttribute || 'id'

        set: (id) ->
          @set(@idAttribute || 'id', id)

    @initialize.apply @, arguments

  get: (key) ->
    @binding.toJS key

  set: (key, val, options) ->
    return @ unless key
    {attrs, options} = @_attrsAndOptions key, val, options

    # Protect from empty merge which triggers binding listeners
    return if _.isEmpty attrs

    tx = @binding.atomically()

    if options.unset
      tx.delete k for k of attrs
    else
      tx.merge Imm.fromJS(attrs)

    # @setStatus 'saved', false, tx

    # Speculative update: set first, then validate
    validationError = @validate?(@toJSON())

    if validationError
      @setStatus 'validationError', Imm.fromJS(validationError), tx
    else
      @unsetStatus 'validationError', tx

    tx.commit options.silent # should be strictly false to silent listeners

    @


  toJSON: ->
    @getCleanState().toJS()

  unsetIfExists: (key) ->
    @unset key if @get key

  # Write model data to the new binding and point @binding to it
  bindTo: (newBinding) ->
    newBinding.set @binding.val()
    @binding = newBinding

  isPending: ->
    @getStatus 'xhr'

  # TODO: add model level transaction
  setStatus: (key, status, tx) ->
    if @options.trackStatus
      {attrs, options: tx} = @_attrsAndOptions key, status, tx
      (if !_.isEmpty tx then tx else @modelStatusBinding).merge Imm.fromJS(attrs)

  unsetStatus: (key, tx) ->
    (if !_.isEmpty tx then tx else @modelStatusBinding).delete key

  getStatus: (key) ->
    @modelStatusBinding.val key

  getCleanState: (state = @binding.val()) ->
    state.delete '__model_status'

  _attrsAndOptions: (key, val, options) ->
    # Handle both `"key", value` and `{key: value}` -style arguments.
    # (from Backbone.Model.set)
    attrs = {}
    if typeof key == 'object'
      attrs = key
      options = val
    else
      attrs[key] = val

    attrs: attrs
    options: options || {}


MoreartySync =
  SyncModel: SyncModel

  createContext: ({state, modelMapping, configuration}) ->
    Ctx = Morearty.createContext state, configuration
    Ctx._modelMap = {}
    Ctx._modelMapRegExps = []
    Ctx._modelInstances = {}

    for {path, model} in modelMapping
      # validateModel ModelOrCollection, SyncModel, 'model'
      # validateModel ModelOrCollection, SyncCollection, 'collection'
      ModelOrCollection = model

      # just split by reg-exps and normal paths
      if path instanceof RegExp
        Ctx._modelMapRegExps.push pathRegExp: path, model: ModelOrCollection
      else
        Ctx._modelMap[path] = ModelOrCollection

    Ctx

  Mixin:
    # lazy model retrieval
    model: (binding = @getDefaultBinding()) ->
      ctx = @context.morearty
      path = Binding.asStringPath binding._path

      model =
        if m = ctx._modelInstances[path]
          m
        else if ModelOrCollection = ctx._modelMap[path]
          ctx._modelInstances[path] = new ModelOrCollection binding
        else if matched = path.match /(.*)\.(\d+)/
          # check if path is a vector item: some.list.x
          [__, vectorPath, itemIndex] = matched
          collection = ctx._modelMap[vectorPath]
          model = collection?.at itemIndex
        else
          # check in regexps
          MClass =
            (ctx._modelMapRegExps.filter (rx) ->
              path.match rx.pathRegExp
            )[0]?.model

          ctx._modelInstances[path] = new MClass binding if MClass

    collection: (binding) ->
      @model binding

    linkModel: (model, path, {beforeEdit, afterEdit}) ->
      beforeEdit ||= _.identity
      afterEdit  ||= _.noop

      (domEvent) ->
        {value} = domEvent.target
        model.binding.set path, beforeEdit(value)
        afterEdit value


  # TODO: need more investigation
  BranchMixin:
    componentWillMount: ->
      @fork()

    componentWillUnmount: ->
      @revert()

    fork: ->
      model = @model()
      model._stateBeforeEdit = model.binding.val()

    revert: ->
      model = @model()
      model.binding.set model._stateBeforeEdit if !model.getStatus('saved')

    saveAndMerge: ->
      @model().save()
      @fork()

    isForkChanged: ->
      model = @model()
      !Imm.is(model.getCleanState(), model.getCleanState(model._stateBeforeEdit))



module.exports = MoreartySync
