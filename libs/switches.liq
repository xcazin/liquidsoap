# At the beginning of each track, select the first ready child.
# @category Source / Track Processing
# @param ~id Force the value of the source ID.
# @param ~override Metadata field which, if present and containing a float, overrides the `transition_length` parameter.
# @param ~replay_metadata Replay the last metadata of a child when switching to it in the middle of a track.
# @param ~track_sensitive Re-select only on end of tracks.
# @param ~transition_length Maximum transition duration.
# @param ~transitions Transition functions, padded with `fun (x,y) -> y` functions.
def fallback(~id=null(), ~override="liq_transition_length", ~replay_metadata=true,
           ~track_sensitive=true, ~transition_length=5., ~transitions=[],
           sources) =
  def add_condition(s) =
    ({true}, s)
  end

  switch(id=id, override=override, replay_metadata=replay_metadata, transitions=transitions,
         track_sensitive=track_sensitive, transition_length=transition_length,
         list.map(add_condition, sources))
end

let stdlib_fallback = fallback

# Special track insensitive fallback that always skips current song before
# switching.
# @category Source / Track Processing
# @flag extra
# @param s The main source.
# @param ~fallback The fallback source.
def fallback.skip(s,~fallback=blank())
  avail = ref(true)
  def check()
    old = !avail
    avail := source.is_ready(s)
    if not old and !avail then
      source.skip(fallback)
    end
  end
  s = stdlib_fallback(track_sensitive=false, [s, fallback])
  # TODO: could we have something more efficient that checking on every frame
  source.on_frame(s, check)
end

# Rotate between sources.
# @category Source / Track Processing
# @param ~id Force the value of the source ID.
# @param ~override Metadata field which, if present and containing a float, overrides the `transition_length` parameter.
# @param ~replay_metadata Replay the last metadata of a child when switching to it in the middle of a track.
# @param ~transition_length Maximum transition duration.
# @param ~transitions Transition functions, padded with `fun (x,y) -> y` functions.
# @param ~weights Weights of the children (padded with 1), defining for each child how many tracks are played from it per round, if that many are actually available.
def rotate(~id=null(), ~override="liq_transition_length", ~replay_metadata=true,
           ~transition_length=5., ~transitions=[],
           ~weights=[], sources) =
  weights = list.map(getter.function, weights)
  picked_index = ref(-1)
  tracks_played = ref(0)
  default_weight = {1}

  def pick() =
    tracks_played := 0

    if list.exists(source.is_ready, sources) then
      def rec f(index) =
        s = list.nth(default=source.fail(), sources, index)
        if source.is_ready(s) then
          picked_index := index
        else
          f((index + 1) mod list.length(sources))
        end
      end
      f((!picked_index+1) mod list.length(sources))
    else
      picked_index := -1
    end
  end

  def add_condition(index, s) =
    weight = list.nth(default=default_weight, weights, index)

    def f(_) =
      tracks_played := !tracks_played + 1
    end

    source.on_track(s, f)

    def cond() =
      if !picked_index == -1 then pick() end

      if !picked_index == index then
        if !tracks_played < weight () then
          true
        else
           pick()
           !picked_index == index
        end
      else
        false
      end
    end

    (cond, s)
  end

  s = switch(override=override, replay_metadata=replay_metadata, track_sensitive=true,
             transition_length=transition_length, transitions=transitions,
             list.mapi(add_condition, sources))

  fallback(id=id, track_sensitive=true, s::sources)
end

# At the beginning of every track, select a random ready child.
# @category Source / Track Processing
# @param ~id Force the value of the source ID.
# @param ~override Metadata field which, if present and containing a float, overrides the `transition_length` parameter.
# @param ~replay_metadata Replay the last metadata of a child when switching to it in the middle of a track.
# @param ~transition_length Maximum transition duration.
# @param ~transitions Transition functions, padded with `fun (x,y) -> y` functions.
# @param ~weights Weights of the children (padded with 1), defining for each child the probability that it is selected.
def replaces random(~id=null(), ~override="liq_transition_length", ~replay_metadata=true,
           ~transition_length=5., ~transitions=[],
           ~weights=[], sources) =
  weights = list.map(getter.function, weights)
  default_weight = fun () -> 1
  next_index = ref(-1)

  def pick() =
    def available_weighted_sources(cur, s) =
      let (index, current_weight, indexes) = cur
      weight = list.nth(default=default_weight, weights, index)

      let (current_weight, indexes) =
        if source.is_ready(s) then
          weight = weight()
          indexes = (current_weight, current_weight+weight, index) :: indexes
          (current_weight + weight, indexes)
        else
          (current_weight, indexes)
        end
    
      (index+1, current_weight, indexes)
    end

    let (_, total_weight, weighted_indexes)  =
      list.fold(available_weighted_sources, (0, 0, []), sources)

    picked_weight =
      if total_weight > 0 then
        random.int(min=0, max=total_weight)
      else
        0
      end
      
    def pick_source(picked_index, el) =
      let (lower_bound, upper_bound, index) = el

      if lower_bound <= picked_weight and picked_weight < upper_bound then
        index
      else
         picked_index
      end
    end
 
    next_index := list.fold(pick_source, -1, weighted_indexes)
  end

  def add_condition(index, s) =
    def f(_) =
      next_index := -1
    end 

    source.on_track(s, f)

    def cond() =
      if !next_index == -1 then pick() end
      !next_index == index  
    end
    
    (cond, s)
  end

  s = switch(override=override, replay_metadata=replay_metadata, track_sensitive=true,
             transition_length=transition_length, transitions=transitions,
             list.mapi(add_condition, sources))

  fallback(id=id, track_sensitive=true, s::sources)
end
