# Default id assignment for playlists
# @category Liquidsoap
# @param ~default Default name pattern when no useful name can be extracted from `uri`
# @param uri Playlist uri
def playlist.id(~default,uri) =
  basename = path.basename(uri)

  basename =
    if basename == "." then
      let l = r/\//g.split(uri)
      if l == [] then
        path.dirname(uri)
      else
        list.hd(list.rev(l))
      end
    else
      basename
    end

  if basename == "." then
    string.id.default(default=default, null())
  else
    basename
  end
end

# Retrieve the list of files contained in a playlist.
# @category Liquidsoap
# @param ~mime_type Default MIME type for the playlist. `null` means automatic \
#  detection.
# @param ~timeout Timeout for resolving the playlist
# @param uri Path to the playlist
def playlist.files(~id=null(), ~mime_type=null(), ~timeout=20., uri) =
  id = id ?? playlist.id(default="playlist.files", uri)
  if file.is_directory(uri) then
    log.info(label=id, "Playlist is a directory.")
    files = file.ls(absolute=true, recursive=true, uri)
    files = list.filter(fun(f) -> not (file.is_directory(f)), files)
    files = list.sort(fun (x,y) -> if x<y then -1 elsif x>y then 1 else 0 end, files)
    files
  else
    pl = request.create(uri)
    result =
      if request.resolve(timeout=timeout, pl) then
        pl = request.filename(pl)
        files = playlist.parse(mime=mime_type, pl)
        def file_request(el) =
          let (meta, file) = el
          s = list.fold(fun (cur, el) ->
          "#{cur},#{fst(el)}=#{string.escape(snd(el))}", "", meta)
          if s == "" then
            file
          else
            "annotate:#{s}:#{file}"
          end
        end
        list.map(file_request, files)
      else
        log.important(label=id, "Couldn't read playlist: request resolution failed.")
        []
      end
    request.destroy(pl)
    result
  end
end

let stdlib_native = native

# Play a list of files.
# @category Source / Input
# @param ~id Force the value of the source ID.
# @param ~check_next Function used to filter next tracks. A candidate track is \
#   only validated if the function returns true on it. The function is called \
#   before resolution, hence metadata will only be available for requests \
#   corresponding to local files. This is typically used to avoid repetitions, \
#   but be careful: if the function rejects all attempts, the playlist will \
#   enter into a consuming loop and stop playing anything.
# @param ~prefetch How many requests should be queued in advance.
# @param ~loop Loop on the playlist.
# @param ~mode Play the files in the playlist either in the order ("normal" mode), \
#  or shuffle the playlist each time it is loaded, and play it in this order for a \
#  whole round ("randomize" mode), or pick a random file in the playlist each time \
#  ("random" mode).
# @param ~native Use native implementation.
# @param ~on_done Function executed when the playlist is finished.
# @param ~max_fail When this number of requests fail to resolve, the whole playlists is considered as failed and `on_fail` is called.
# @param ~on_fail Function executed when too many requests failed and returning the contents of a fixed playlist.
# @param ~timeout Timeout (in sec.) for a single download.
# @param playlist Playlist.
# @method reload Reload the playlist with given list of songs.
def playlist.list(~id=null(), ~check_next=null(), ~prefetch=1, ~loop=true,
                  ~mode="normal", ~native=false, ~on_done={()}, ~max_fail=10, ~on_fail=null(), ~timeout=20., playlist)
  id = string.id.default(default="playlist.list", id)
  mode =
    if not list.mem(mode, ["normal", "random", "randomize"]) then
      log.severe(label=id, "Invalid mode: #{mode}"); "randomize"
    else mode end

  # Original playlist when loaded
  playlist_orig = ref(playlist)

  # Randomize the playlist if necessary
  def randomize(p)
    if mode == "randomize" then
      list.shuffle(p)
    else
      p
    end
  end

  # Current remaining playlist
  playlist = ref(randomize(playlist))

  # A reference to know if the source has been stopped
  has_stopped = ref(false)

  # Delay the creation of next after the source because we need it to resolve
  # requests at the right content type.
  next_fun = ref(fun () -> [])

  def next()
    f = !next_fun
    f()
  end

  # Instantiate the source
  s =
    if native then
      stdlib_native.request.dynamic.list(id=id, next)
    else
      request.dynamic.list(id=id, prefetch=prefetch, timeout=timeout, retry_delay=1., available={not !has_stopped}, next)
    end
  source.set_name(s, "playlist.list.reloadable")

  # The reload function
  def reload(p) =
    log.debug(label=id, "Reloading playlist.")
    playlist_orig := p
    playlist := randomize(!playlist_orig)
    has_stopped := false
  end

  # When we have more than max_fail failures in a row, we wait for 1 second
  # before trying again in order to avoid infinite loops.
  failed_count = ref(0)
  failed_time = ref(0.)

  # The (real) next function
  def rec next() =
    if loop and list.length(!playlist) == 0 then playlist := randomize(!playlist_orig) end
    file =
      if list.length(!playlist) > 0 then
        if mode == "random" then
          n = random.int(min=0, max=list.length(!playlist))
          list.nth(default="", !playlist, n)
        else
          ret = list.hd(default="", !playlist)
          playlist := list.tl(!playlist)
          ret
        end
      else
        # Playlist finished
        if not !has_stopped then
          has_stopped := true
          log.info(label=id, "Playlist stopped.")
          on_done()
        end
        ""
      end
    if file == "" or (!failed_count >= max_fail and time() < !failed_time + 1.) then
      # Playlist failed too many times recently, don't try next for now.
      []
    else
      log.debug(label=id, "Next song will be \"#{file}\".")
      r = request.create(file)
      if not request.resolve(content_type=s, r) then
        log.info(label=id, "Could not resolve request: #{request.uri(r)}.")
        ref.incr(failed_count)
        # Playlist failed, call handler.
        if !failed_count >= max_fail then
          log.info(label=id, "Playlist failed.")
          if null.defined(on_fail) then
            f = null.get(on_fail)
            reload(f())
          end
        end
        failed_time := time()
        next()
      elsif null.defined(check_next) then
        check_next = null.get(check_next)
        failed_count := 0
        if check_next(r) then
          [r]
        else
          log.info(label=id, "Request #{request.uri(r)} rejected by check_next.")
          request.destroy(r)
          next()
        end
      else
        # We accept everything by default
        [r]
      end
    end
  end

  next_fun := next

  # Return
  s.{reload = reload}
end

# Read a playlist or a directory, play all files and stop. It returns a pair
# `(reload,source)` where `reload` is a function of type `(?uri:string)->unit`
# that can be used to reload the source and `source` is the actual source. The
# reload function can optionally be called with a new playlist URI, otherwise,
# it reloads the previous URI.
# @category Source / Input
# @param ~id Force the value of the source ID.
# @param ~check_next Function used to filter next tracks. A candidate track is \
#   only validated if the function returns true on it. The function is called \
#   before resolution, hence metadata will only be available for requests \
#   corresponding to local files. This is typically used to avoid repetitions, \
#   but be careful: if the function rejects all attempts, the playlist will \
#   enter into a consuming loop and stop playing anything.
# @param ~prefetch How many requests should be queued in advance.
# @param ~loop Loop on the playlist.
# @param ~mime_type Default MIME type for the playlist. `null` means \
#  automatic detection.
# @param ~mode Play the files in the playlist either in the order ("normal" mode), \
#  or shuffle the playlist each time it is loaded, and play it in this order for a \
#  whole round ("randomize" mode), or pick a random file in the playlist each time \
#  ("random" mode).
# @param ~native Use native implementation.
# @param ~on_done Function executed when the playlist is finished.
# @param ~on_reload Callback called after playlist has reloaded.
# @param ~prefix Add a constant prefix to all requests. Useful for passing extra \
#  information using annotate, or for resolution through a particular protocol, \
#  such as replaygain.
# @param ~timeout Timeout (in sec.) for a single download.
# @param uri Playlist URI.
# @method reload Reload the playlist.
# @method length Length of the of the playlist (the number of songs it contains).
def playlist.reloadable(
  ~id=null(), ~check_next=null(), ~prefetch=1, ~loop=true, ~mime_type=null(),
  ~mode="randomize", ~native=false, ~on_done={()}, ~on_reload=(fun (_) -> ()),
  ~prefix="", ~timeout=20., uri) =
  id = id ?? playlist.id(default="playlist.reloadable", uri)
  # URI of the current playlist
  playlist_uri=ref(uri)
  # List of files in the current playlist
  files=ref([])

  # The load function
  def load_playlist() =
    playlist_uri = path.home.unrelate(!playlist_uri)
    log.info(label=id, "Reloading playlist.")
    files = playlist.files(id=id, mime_type=mime_type, timeout=timeout, playlist_uri)
    list.map(fun(file) -> prefix^file, files)
  end

  # Try to reload playlist when the playlist is looped and has failed.
  def on_fail()
    l = load_playlist()
    if l == [] then
      log.info("Failed to reload playlist after failure.")
      # We add a dummy request in order for the playlist not to stop.
      ["???failed???"]
    else
      log.info("Successfully reload playlist after failure.")
      l
    end
  end
  on_fail = if loop then on_fail else null() end

  # Create the source
  files := load_playlist()

  s = playlist.list(
    id=id, check_next=check_next, prefetch=prefetch, loop=loop, mode=mode,
    native=native, on_done=on_done, on_fail=on_fail, timeout=timeout, !files)

  source.set_name(s, "playlist.reloadable")

  # The reload function
  def reload(~uri=null()) =
    if null.defined(uri)  then
      playlist_uri := null.get(uri)
    end
    log(label=id,"Reloading playlist with URI #{!playlist_uri}.")
    files := load_playlist()
    s.reload(!files)
    on_reload(!playlist_uri)
  end

  def length() =
    list.length(!files)
  end

  s.{reload = reload, length = length}
end

# Read a playlist or a directory and play all files.
# @category Source / Input
# @param ~id Force the value of the source ID.
# @param ~check_next Function used to filter next tracks. A candidate track is \
#   only validated if the function returns true on it. The function is called \
#   before resolution, hence metadata will only be available for requests \
#   corresponding to local files. This is typically used to avoid repetitions, \
#   but be careful: if the function rejects all attempts, the playlist will \
#   enter into a consuming loop and stop playing anything.
# @param ~prefetch How many requests should be queued in advance.
# @param ~loop Loop on the playlist.
# @param ~mime_type Default MIME type for the playlist. `null` means automatic \
#  detection.
# @param ~mode Play the files in the playlist either in the order ("normal" mode), \
#  or shuffle the playlist each time it is loaded, and play it in this order for a \
#  whole round ("randomize" mode), or pick a random file in the playlist each time \
#  ("random" mode).
# @param ~native Use native implementation.
# @param ~on_reload Callback called after playlist has reloaded.
# @param ~prefix Add a constant prefix to all requests. Useful for passing extra \
#  information using annotate, or for resolution through a particular protocol, \
#  such as replaygain.
# @param ~reload Amount of time (in seconds or rounds), when applicable, before \
#  which the playlist is reloaded; 0 means never.
# @param ~reload_mode Unit of the reload parameter, either "never" (never reload \
#  the playlist), "rounds", "seconds" or "watch" (reload the file whenever it is \
#  changed).
# @param ~timeout Timeout (in sec.) for a single download.
# @param uri Playlist URI.
# @method reload Reload the playlist.
# @method length Length of the of the playlist (the number of songs it contains).
def replaces playlist(
  ~id=null(), ~check_next=null(), ~prefetch=1, ~loop=true, 
  ~mime_type=null(), ~mode="randomize", ~native=false, ~on_reload=(fun (_) -> ()),
  ~prefix="", ~reload=0, ~reload_mode="seconds", ~timeout=20., uri) =
  id = id ?? playlist.id(default="playlist", uri)

  reload_mode =
    if not list.mem(reload_mode, ["never", "rounds", "seconds", "watch"]) then
      log.severe(label=id, "Invalid reload mode: #{mode}"); "seconds"
    else
      reload_mode
    end

  uri = ref(uri)
  round = ref(0)

  # Will be filled with the actual reload function
  reloader_ref = ref(fun()->())

  # Reload when the playlist is done
  def on_done()
    reloader = !reloader_ref
    if reload_mode == "rounds" and reload > 0 then
      round := !round + 1
      if !round >= reload then
        round := 0
        reloader()
      end
    end
  end

  watcher_reload_ref = ref(fun (_) -> ())

  def on_reload(uri) =
    watcher_reload = !watcher_reload_ref
    watcher_reload(uri)
    on_reload(uri)
  end 

  s = playlist.reloadable(
    id=id, check_next=check_next, prefetch=prefetch, loop=loop,
    mime_type=mime_type, mode=mode, native=native, on_done=on_done,
    prefix=prefix, timeout=timeout, on_reload=on_reload, !uri)

  reloader_ref := s.reload

  source.set_name(s, "playlist")

  # Set up reloading for seconds and watch
  if reload_mode == "seconds" and reload > 0 then
    n = float_of_int(reload)
    thread.run(delay=n, every=n, s.reload)
  elsif reload_mode == "watch" then
    watcher =
      if file.exists(!uri) then
         ref(null(file.watch(!uri, s.reload)))
      else
         ref(null())
      end

    watched_uri = ref(!uri)

    def watcher_reload(uri) =
      if uri != !watched_uri then
        w = !watcher
          
        if null.defined(w) then
          null.get(w).unwatch()
        end

        watched_uri := uri
        watcher :=
           if file.exists(uri) then
             file.watch(uri, s.reload)
           else
             null()
           end
      end
    end
    watcher_reload_ref := watcher_reload

    def watcher_shutdown() =
      w = !watcher
      if null.defined(w) then
        null.get(w).unwatch()
      end
    end
    s.on_shutdown(watcher_shutdown)
  end

  # Set up telnet commands
  server.register(namespace=id, description="Skip current song in the playlist.", usage="skip", "skip", fun (_) -> begin s.skip(); "OK" end)
  server.register(namespace=id, description="Return up to 10 next URIs to be played.", usage="next", "next", fun (n) -> begin
    n = max(10, int_of_string(default=10, n))
    requests = list.fold((fun (cur, el) -> list.length(cur) < n ? [...cur, el] : cur), [], s.queue())
    string.concat(separator="\n", list.map((fun (r) -> begin
      m = request.metadata(r)
      get = fun (lbl) -> list.assoc(default="?", lbl, m)
      status = get("status")
      uri = get("initial_uri")
      "[#{status}] #{uri}"
    end), requests))
  end)
  server.register(namespace=id, description="Reload the playlist, unless already being loaded.", usage="reload", "reload", fun (_) -> begin s.reload(); "OK" end)

  def uri_cmd (uri') =
    if uri' == "" then !uri
    else
      if reload_mode == "watch" then
        log.important(label=id, "Warning: the watched file is not updated for now when changing the uri!")
      end # TODO
      uri := uri'
      s.reload(uri=uri')
      "OK"
    end
  end
  server.register(namespace=id, description="Print playlist URI if called without an argument, otherwise set a new one and load it.", usage="uri [<uri>]", "uri", uri_cmd)

  s
end
