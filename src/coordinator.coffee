
debug = require('debug')('msgflo:coordinator')
EventEmitter = require('events').EventEmitter
fs = require 'fs'
async = require 'async'

setup = require './setup'

findPort = (def, type, portName) ->
  ports = if type == 'inport' then def.inports else def.outports
  for port in ports
    return port if port.id == portName
  return null

connId = (fromId, fromPort, toId, toPort) ->
  return "#{fromId} #{fromPort} -> #{toPort} #{toId}"
fromConnId = (id) ->
  t = id.split ' '
  return [ t[0], t[1], t[4], t[3] ]
iipId = (part, port) ->
  return "#{part} #{port}"
fromIipId = (id) ->
  return id.split ' '


class Coordinator extends EventEmitter
  constructor: (@broker, @initialGraph, @library) ->
    @participants = {}
    @connections = {} # connId -> { queue: opt String, handler: opt function }
    @iips = {} # iipId -> value
    @started = false
    @processes = null
    @on 'participant', @checkParticipantConnections

  start: (callback) ->
    @broker.connect (err) =>
      debug 'connected', err
      return callback err if err
      @broker.subscribeParticipantChange (msg) =>
        @handleFbpMessage msg.data
        @broker.ackMessage msg
      @started = true
      debug 'started', err, @started
      return callback null

  stop: (callback) ->
    @started = false
    @broker.disconnect (err) =>
      return callback err if err
      setup.killProcesses @processes, 'SIGTERM', callback

  handleFbpMessage: (data) ->
    if data.protocol == 'discovery' and data.command == 'participant'
      @addParticipant data.payload
    else
      throw new Error 'Unknown FBP message'

  addParticipant: (definition) ->
    debug 'addParticipant', definition.id
    @participants[definition.id] = definition
    @emit 'participant-added', definition
    @emit 'participant', 'added', definition

  removeParticipant: (id) ->
    definition = @participants[id]
    @emit 'participant-removed', definition
    @emit 'participant', 'removed', definition

  sendTo: (participantId, inport, message) ->
    debug 'sendTo', participantId, inport, message
    part = @participants[participantId]
    port = findPort part, 'inport', inport
    @broker.sendTo 'inqueue', port.queue, message, (err) ->
      throw err if err

  subscribeTo: (participantId, outport, handler) ->
    part = @participants[participantId]
    debug 'subscribeTo', participantId, outport
#    console.log part.outports, outport
    port = findPort part, 'outport', outport
    ackHandler = (msg) =>
      return if not @started
      handler msg
      @broker.ackMessage msg
    @broker.subscribeToQueue port.queue, ackHandler, (err) ->
      throw err if err

  unsubscribeFrom: () -> # FIXME: implement

  connect: (fromId, fromPort, toId, toName) ->
    findQueue = (partId, dir, portName) =>
      part = @participants[partId]
      for port in part[dir]
        return port.queue if port.id == portName

    edge =
      fromId: fromId
      fromPort: fromPort
      toId: toId
      toName: toName
      srcQueue: findQueue fromId, 'outports', fromPort
      tgtQueue: findQueue toId, 'inports', toName

    # TODO: support roundtrip
    @broker.addBinding {type: 'pubsub', src:edge.srcQueue, tgt:edge.tgtQueue}, (err) =>
      id = connId fromId, fromPort, toId, toName
      @connections[id] = edge

    # TODO: introduce some "spying functionality" to provide edge messages, add tests

  disconnect: (fromId, fromPortId, toId, toPortId) -> # FIXME: implement


  checkParticipantConnections: (action, participant) ->
    findConnectedPorts = (dir, srcPort) =>
      conn = []
      # return conn if not srcPort.queue
      for id, part of @participants
        for port in part[dir]
          continue if not port.queue
          conn.push { part: part, port: port } if port.queue == srcPort.queue
      return conn

    isConnected = (e) =>
      [fromId, fromPort, toId, toPort] = e
      id = connId fromId, fromPort, toId, toPort
      return @connections[id]?

    if action == 'added'
      id = participant.id
      # inbound
      for port in participant.inports
        matches = findConnectedPorts 'outports', port
        for m in matches
          e = [m.part.id, m.port.id, id, port.id]
          @connect e[0], e[1], e[2], e[3] if not isConnected e

      # outbound
      for port in participant.outports
        matches = findConnectedPorts 'inports', port
        for m in matches
          e = [id, port.id, m.part.id, m.port.id]
          @connect e[0], e[1], e[2], e[3] if not isConnected e

    else if action == 'removed'
      null # TODO: implement

    else
      null # ignored

  addInitial: (partId, portId, data) ->
    id = iipId partId, portId
    @iips[id] = data
    @sendTo partId, portId, data if @started

  removeInitial: (partId, portId) -> # FIXME: implement
    # Do we need to remove it from the queue??

  serializeGraph: (name) ->
    graph =
      properties:
        name: name
      processes: {}
      connections: []
      inports: []
      outports: []

    for id, part of @participants
      graph.processes[id] =
        component: part.component

    for id, conn of @connections
      parts = fromConnId id
      edge =
        src:
          process: parts[0]
          port: parts[1]
        tgt:
          process: parts[2]
          port: parts[3]
      graph.connections.push edge

    return graph

  loadGraphFile: (path, callback) ->
    options =
      graphfile: path
      libraryfile: @library.configfile
    setup.participants options, (err, proc) =>
      return callback err if err
      @processes = proc
      setup.bindings options, callback

  participantsByRole: (role) ->
    matchRole = (id) =>
      part = @participants[id]
      return part.role == role

    m = Object.keys(@participants).filter matchRole
    return m


exports.Coordinator = Coordinator
