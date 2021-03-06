#!../node_modules/coffee-script/bin/coffee

# includes
http = require 'http'

# defines
ANNOUNCE_INTERVAL = 1800 # 30 mins
MIN_INTERVAL      = 60
DROP_COUNT        = 3

# helper functions
simple_response = (res, data) ->
  res.setHeader 'Content-Type', 'text/plain'
  res.end (bencode data)

compact = (ip, port) -> (new Buffer ip.split('.').concat([port >> 8, port & 0xFF])).toString 'base64'

parse = (qs) ->
  obj = {}
  for kvp in qs.split '&'
    obj[kvp.substr(0, x)] = kvp.substr(x + 1) if ~(x = kvp.indexOf '=')
  obj

#bencode.bencode = (o) -> new Buffer 1
bencode_str = (o) ->
  bstring = (s) -> s.length + ':' + s
  bint = (n) -> "i#{n}e"
  blist = (l) ->
    buf = 'l'
    buf += bencode_str i for i in l
    buf + 'e'
  bdict = (d) ->
    buf = 'd'
    buf += bstring(k) + bencode_str(d[k]) for k in Object.keys(d).sort()
    buf + 'e'
  bbuffer = (b) ->
    out = b.length + ':'
    if b.length == 0
      return out
    for i in [0..b.length-1]
      out = out + String.fromCharCode(b[i])
    return out

  switch typeof o
    when 'string' then out = bstring o
    when 'number' then out = bint    o
    when 'object'
      if o instanceof Array
        out = blist o
      else if o instanceof Buffer
        out = bbuffer o
      else if o?
        out = bdict o
      else
        throw new Error('cannot encode element null')
    else
      throw new Error('cannot encode element ' + o)
  return out
bencode = (o) ->
  out = bencode_str o
  out_buf = new Buffer out.length
  for i in [0..out.length-1]
    out_buf[i] = out.charCodeAt i
  return out_buf


decodeURLtoHex = (str) ->
  output = ''
  i = 0
  while i < str.length
    if (str.charCodeAt i)== 37
      output += str[i+1] + str[i+2]
      i += 2
    else
      output += (str.charCodeAt i).toString 16
    i += 1
  return output.toLowerCase()

HextoDec = (str) ->
  output = ''
  for i in [0..str.length-1] by 2
    output += String.fromCharCode parseInt str[i] + str[i+1], 16
  return output

# Tracker class
class Tracker
  constructor: (port) ->
    # redis
    @redis = require('redis').createClient 6379, '127.0.0.1' #, {'return_buffers' : true})

    # mongodb
    @torrents = null
    mongo = require('mongodb')
    db = new mongo.Db 'uguutracker', new mongo.Server('localhost', mongo.Connection.DEFAULT_PORT, {native_praser: true})
    db.open (err, db) =>
      throw new Error('could not open db') if err?
      console.log 'connected to mongodb'
      db.collection 'torrents', (err, @torrents) =>
        throw new Error('could not open collection') if err?

    # http server
    http.createServer (req, res) =>
      console.log req.url
      if req.url.substr(0, 9) is '/announce'
        if query = req.url.split('?', 2)[1]
          @announce query, req, res
        else
          res.end '!?'
      else if req.url.substr(0, 7) is '/scrape'
        if query = req.url.split('?', 2)[1]
          @scrape query, req, res
        else
          res.end '!?'
      else
        res.end '!?'

    # HEY! LISTEN!
    .listen port

  announce: (query, req, res) ->
    get_vars = parse query
    return simple_response res, {'failure reason': 'Invalid Request'} unless get_vars['info_hash']? and get_vars['peer_id']?

    # GET requests of interest are:
    #   info_hash, peer_id, port, uploaded, downloaded, left,   <--- REQUIRED
    #   compact, no_peer_id, event, ip, numwant, key, trackerid <--- optional
    info_hash = decodeURLtoHex get_vars['info_hash']

    port = parseInt get_vars['port']
    left = parseInt get_vars['left']
    if info_hash == '' or get_vars['peer_id'] == '' or isNaN(port) or isNaN(left)
      return simple_response res, {'failure reason': 'Invalid Request'}

    key = 'torrent:' + info_hash
    key_peer = key + ':peers'
    key_seed = key + ':seeds'

    #get redis etc..
    redis = @redis

    check_exists = (callback) =>
      #callback()
      #return
      redis.ZCARD key_seed, (err, data)=>
        if data != 0
          callback()
        else
          redis.ZCARD key_peer, (err, data)=>
            if data != 0
              callback()
            else
              console.log 'mongo ' + info_hash
              @torrents.findOne {'infohash' : info_hash}, (err, exists) =>
                if exists
                  callback()
                else
                  return simple_response res, {'failure reason': 'This torrent does not exist'}

    check_exists =>
      event = get_vars['event']
      if event == 'stopped' or event == 'paused'
        return simple_response res, 'Nani?'

      t = Date.now()
      multi = redis.multi()
        .ZREMRANGEBYSCORE(key_seed, 0, t - ANNOUNCE_INTERVAL * DROP_COUNT * 1000)
        .ZREMRANGEBYSCORE(key_peer, 0, t - ANNOUNCE_INTERVAL * DROP_COUNT * 1000)

      ip = get_vars['ip'] #REALLY SHOULD CHECK THIS IS A VALID IP
      ip = req.connection.remoteAddress unless ip?
      return unless ip?
      #ip = process.env['HTTP_X_REAL_IP'] if ip is '127.0.0.1'

      peer_entry = { 'ip' : ip, 'port' : port, 'peer_id' : get_vars['peer_id'], 'compacted' : compact(ip, port) }

      suffix = if (left == 0) then ":seeds" else ":peers"
      multi.ZADD key + suffix, t, JSON.stringify(peer_entry)

      if event == 'completed' #increment snatch
        @torrents.update {'infohash': info_hash}, {$inc: {'snatches': 1}}
      # Output now. Fields are:
      #   interval, complete, incomplete, peers (dict|bin) <--- REQUIRED
      #   min interval, tracker id, warning message        <--- optional

      numwant = parseInt get_vars['numwant']
      numwant = 50 if isNaN(numwant) or numwant < 0 or numwant > 50

      multi
        .ZCARD(key_seed)
        .ZCARD(key_peer)
        .ZRANGE(key_seed, 0, numwant)
        .ZRANGE(key_peer, 0, numwant)
        .exec (err, replies) =>

          if err? then return simple_response res, {'failure reason': 'wat'}
          doCompact = get_vars['compact'] is '1'
          peerlist = replies[5].concat(replies[6])
            .slice(0, numwant)
            .map (p) ->
              peer_entry = JSON.parse p
              if doCompact
                return peer_entry['compacted']
              else
                delete peer_entry['compacted']
                return peer_entry
          if doCompact
            peerlist = peerlist.join ''
            peerlist = new Buffer peerlist, 'base64'

          return simple_response res,
            'interval'     : ANNOUNCE_INTERVAL
            'complete'     : replies[3]
            'incomplete'   : replies[4]
            'min interval' : MIN_INTERVAL
            'peers'        : peerlist

  scrape: (query, req, res) ->
    info_hashes = []
    for kvp in query.split '&'
      if kvp[0...9] is "info_hash"
        info_hashes.push decodeURLtoHex kvp[10...]

    # Require at least one info_hash; no support for sitewide scraping.
    return simple_response res, {'failure reason': 'Invalid Request'} if info_hashes.length == 0

    multi = @redis.multi()
    files = {}
    @torrents.find({ 'infohash' : {$in:info_hashes} }).toArray (err, docs) =>
      return simple_response res, {'failure reason': 'No valid hashes requested'} if docs.length is 0
      infohash = []
      snatches = [] # downloaded
      for i in [0...docs.length]
        ih = docs[i].infohash
        key = 'torrent:' + ih
        infohash.push ih
        snatches.push docs[i].snatches
        multi
          .ZCARD(key + ':peers') # incomplete
          .ZCARD(key + ':seeds') # complete

      multi.exec (err, reply) -> # no real error checking here because the hashes returned by mongo should all be valid.
        j = 0
        for hash,i in infohash
          conv = HextoDec hash
          files[conv] = {}
          files[conv].downloaded = snatches[i]
          files[conv].incomplete = reply[j]
          files[conv].complete = reply[j+1]
          j+=2
        return simple_response res, {files}

port = parseInt(process.argv[2]) || 9001
console.log ('Starting tracker on 127.0.0.1:' + port + '...')
new Tracker port
