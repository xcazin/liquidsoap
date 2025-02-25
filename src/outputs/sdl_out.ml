(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2021 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

open Mm

(** Output using SDL lib. *)

open Tsdl

class output ~infallible ~on_start ~on_stop ~autostart ~kind source =
  let video_width = Lazy.force Frame.video_width in
  let video_height = Lazy.force Frame.video_height in
  let () = Sdl_utils.init [Sdl.Init.video] in
  object (self)
    inherit
      Output.output
        ~name:"sdl" ~output_kind:"output.sdl" ~infallible ~on_start ~on_stop
          ~content_kind:(Source.Kind.of_kind kind) source autostart

    val mutable fullscreen = false
    val mutable window = None

    method start =
      window <-
        Some
          (Sdl_utils.check
             (fun () ->
               Sdl.create_window "Liquidsoap" ~w:video_width ~h:video_height
                 Sdl.Window.windowed)
             ());
      self#log#info "Initialized SDL video surface."

    (** We don't care about latency. *)
    method reset = ()

    (** Stop SDL. We have to assume that there's only one SDL output anyway. *)
    method stop = Sdl.quit ()

    method process_events =
      let e = Sdl.Event.create () in
      if Sdl.poll_event (Some e) then (
        match Sdl.Event.(enum (get e typ)) with
          | `Quit ->
              (* Avoid an immediate restart (which would happen with autostart). But
                 do not cancel autostart. We should perhaps have a method in the
                 output class for that kind of thing, and try to get an uniform
                 behavior. *)
              self#transition_to `Stopped;
              self#transition_to `Started
          | `Key_down ->
              (let k = Sdl.Event.(get e keyboard_keycode) in
               match k with
                 | k when k = Sdl.K.f ->
                     fullscreen <- not fullscreen;
                     Sdl_utils.check
                       (fun () ->
                         Sdl.set_window_fullscreen (Option.get window)
                           (if fullscreen then Sdl.Window.fullscreen
                           else Sdl.Window.windowed))
                       ()
                 | k when k = Sdl.K.q ->
                     let e = Sdl.Event.create () in
                     Sdl.Event.(set e typ quit);
                     assert (Sdl_utils.check Sdl.push_event e)
                 | _ -> ());
              self#process_events
          | _ -> self#process_events)

    method send_frame buf =
      self#process_events;
      let window = Option.get window in
      let surface = Sdl_utils.check Sdl.get_window_surface window in
      (* We only display the first image of each frame *)
      let rgb = Video.get (VFrame.yuva420p buf) 0 in
      Sdl_utils.Surface.of_img surface rgb;
      Sdl_utils.check Sdl.update_window_surface window
  end

let () =
  let kind = Lang.video_yuva420p in
  let k = Lang.kind_type_of_kind_format kind in
  Lang.add_operator "output.sdl"
    (Output.proto @ [("", Lang.source_t k, None, None)])
    ~return_t:k ~category:`Output ~descr:"Display a video using SDL."
    (fun p ->
      let autostart = Lang.to_bool (List.assoc "start" p) in
      let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
      let on_start =
        let f = List.assoc "on_start" p in
        fun () -> ignore (Lang.apply f [])
      in
      let on_stop =
        let f = List.assoc "on_stop" p in
        fun () -> ignore (Lang.apply f [])
      in
      let source = List.assoc "" p in
      (new output ~infallible ~autostart ~on_start ~on_stop ~kind source
        :> Source.source))

let () =
  Lang.add_builtin
    ~category:(`Source `Output)
    ~descr:"Check whether video output is available with SDL."
    "output.sdl.has_video" [] Lang.bool_t
    (fun _ ->
      match Sdl.init Sdl.Init.video with
        | Ok _ -> Lang.bool true
        | Error _ -> Lang.bool false)
