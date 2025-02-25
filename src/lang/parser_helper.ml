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

(** Helper functions for the parser. *)

open Term
open Ground

type let_decoration = [ `None | `Recursive | `Replaces | `Eval ]

let string_of_let_decoration = function
  | `None -> ""
  | `Recursive -> "rec"
  | `Replaces -> "replaces"
  | `Eval -> "eval"

let gen_args_of ~only ~except ~pos get_args name =
  match Environment.get_builtin name with
    | Some ((_, t), Value.{ value = Fun (args, _, _, _) })
    | Some ((_, t), Value.{ value = FFI (args, _, _) }) ->
        let filtered_args = List.filter (fun (n, _, _) -> n <> "") args in
        let filtered_args =
          if only <> [] then
            List.map
              (fun n ->
                try List.find (fun (n', _, _) -> n = n') filtered_args
                with Not_found ->
                  raise
                    (Parse_error
                       ( pos,
                         Printf.sprintf
                           "Builtin %s does not have an argument named %s" name
                           n )))
              only
          else filtered_args
        in
        List.iter
          (fun n ->
            match List.find_opt (fun (n', _, _) -> n = n') args with
              | Some _ -> ()
              | None ->
                  raise
                    (Parse_error
                       ( pos,
                         Printf.sprintf
                           "Builtin %s does not have an argument named %s" name
                           n )))
          except;
        let filtered_args =
          List.filter (fun (n, _, _) -> not (List.mem n except)) filtered_args
        in
        get_args ~pos t filtered_args
    | Some _ ->
        raise
          (Parse_error (pos, Printf.sprintf "Builtin %s is not a function!" name))
    | None ->
        raise
          (Parse_error (pos, Printf.sprintf "Builtin %s is not registered!" name))

let args_of, app_of =
  let rec get_args ~pos t args =
    let get_arg_type t name =
      match (Type.deref t).Type.descr with
        | Type.Arrow (l, _) ->
            let _, _, t = List.find (fun (_, n, _) -> n = name) l in
            t
        | _ ->
            raise
              (Parse_error
                 ( pos,
                   Printf.sprintf
                     "Cannot get argument type of %s, this is not a function, \
                      it has type: %s."
                     name (Type.print t) ))
    in
    List.map
      (fun (n, n', v) ->
        let t = Type.make ~pos (get_arg_type t n).Type.descr in
        (n, n', t, Option.map (term_of_value ~pos t) v))
      args
  and get_app ~pos _ args =
    List.map
      (fun (n, _, _) -> (n, Term.{ t = Type.var ~pos (); term = Var n }))
      args
  and term_of_value ~pos t ({ Value.value } as v) =
    let get_list_type () =
      match (Type.deref t).Type.descr with
        | Type.List t -> t
        | _ -> assert false
    in
    let get_tuple_type pos =
      match (Type.deref t).Type.descr with
        | Type.Tuple t -> List.nth t pos
        | _ -> assert false
    in
    let get_meth_type () =
      match (Type.deref t).Type.descr with
        | Type.Meth (_, _, _, t) -> t
        | _ -> assert false
    in
    let term =
      match value with
        | Value.Ground g -> Term.Ground g
        | Value.List l ->
            Term.List (List.map (term_of_value ~pos (get_list_type ())) l)
        | Value.Tuple l ->
            Term.List
              (List.mapi
                 (fun idx v -> term_of_value ~pos (get_tuple_type idx) v)
                 l)
        | Value.Null -> Term.Null
        | Value.Meth (name, v, v') ->
            let t = get_meth_type () in
            Term.Meth (name, term_of_value ~pos t v, term_of_value ~pos t v')
        | Value.Fun (args, [], [], body) ->
            let body =
              Term.{ body with t = Type.make ~pos body.t.Type.descr }
            in
            Term.Fun (Term.free_vars body, get_args ~pos t args, body)
        | _ ->
            raise
              (Parse_error
                 ( pos,
                   Printf.sprintf "Term %s cannot be represented as a term"
                     (Value.print_value v) ))
    in
    let t = Type.make ~pos t.Type.descr in
    Term.{ t; term }
  in
  let args_of = gen_args_of get_args in
  let app_of = gen_args_of get_app in
  (args_of, app_of)

let mk = Term.make

let append_list ~pos x v =
  match (x, v) with
    | `Expr x, `List l -> `List (x :: l)
    | `Expr x, `App v ->
        let list = mk ~pos (Var "list") in
        let op = mk ~pos (Invoke (list, "add")) in
        `App (mk ~pos (App (op, [("", x); ("", v)])))
    | `Ellipsis x, `App v ->
        let list = mk ~pos (Var "list") in
        let op = mk ~pos (Invoke (list, "append")) in
        `App (mk ~pos (App (op, [("", x); ("", v)])))
    | `Ellipsis x, `List l ->
        let list = mk ~pos (Var "list") in
        let op = mk ~pos (Invoke (list, "append")) in
        let l = mk ~pos (List l) in
        `App (mk ~pos (App (op, [("", x); ("", l)])))

let mk_list ~pos = function `List l -> mk ~pos (List l) | `App a -> a

let mk_fun ~pos args body =
  let bound = List.map (fun (_, x, _, _) -> x) args in
  let fv = Term.free_vars ~bound body in
  mk ~pos (Fun (fv, args, body))

let mk_rec_fun ~pos pat args body =
  let name =
    match pat with
      | PVar l when l <> [] -> List.hd (List.rev l)
      | _ -> assert false
  in
  let bound = List.map (fun (_, x, _, _) -> x) args in
  let bound = name :: bound in
  let fv = Term.free_vars ~bound body in
  mk ~pos (RFun (name, fv, args, body))

let mk_eval ~pos (doc, pat, def, body, cast) =
  let ty =
    match cast with Some ty -> ty | None -> Type.var ~level:(-1) ~pos ()
  in
  let tty = Value.RuntimeType.to_term ty in
  let eval = mk ~pos (Var "_eval_") in
  let def = mk ~pos (App (eval, [("type", tty); ("", def)])) in
  let def = mk ~pos (Cast (def, ty)) in
  mk ~pos (Let { doc; replace = false; pat; gen = []; def; body })

let mk_let ~pos (doc, decoration, pat, arglist, def, cast) body =
  match (arglist, decoration) with
    | Some arglist, `None | Some arglist, `Replaces ->
        let replace = decoration = `Replaces in
        let def = mk_fun ~pos arglist def in
        let def =
          match cast with Some ty -> mk ~pos (Cast (def, ty)) | None -> def
        in
        mk ~pos (Let { doc; replace; pat; gen = []; def; body })
    | Some arglist, `Recursive ->
        let def = mk_rec_fun ~pos pat arglist def in
        let def =
          match cast with Some ty -> mk ~pos (Cast (def, ty)) | None -> def
        in
        mk ~pos (Let { doc; replace = false; pat; gen = []; def; body })
    | None, `None | None, `Replaces ->
        let replace = decoration = `Replaces in
        let def =
          match cast with Some ty -> mk ~pos (Cast (def, ty)) | None -> def
        in
        mk ~pos (Let { doc; replace; pat; gen = []; def; body })
    | None, `Eval -> mk_eval ~pos (doc, pat, def, body, cast)
    | Some _, v ->
        raise
          (Parse_error
             ( pos,
               string_of_let_decoration v
               ^ " does not apply to function assignments" ))
    | None, v ->
        raise
          (Parse_error
             ( pos,
               string_of_let_decoration v
               ^ " only applies to function assignments" ))

let mk_encoder ~pos e p = mk ~pos (Encoder (e, p))

(** Time intervals *)

let time_units = [| 7 * 24 * 60 * 60; 24 * 60 * 60; 60 * 60; 60; 1 |]

(** Given a date specified as a list of four values (whms), return a date in
    seconds from the beginning of the week. *)
let date ~pos =
  let to_int = function None -> 0 | Some i -> i in
  let rec aux = function
    | None :: tl -> aux tl
    | [] -> raise (Parse_error (pos, "Invalid time."))
    | l ->
        let a = Array.of_list l in
        let n = Array.length a in
        let tu = time_units and tn = Array.length time_units in
        Array.fold_left ( + ) 0
          (Array.mapi
             (fun i s ->
               let s = if n = 4 && i = 0 then to_int s mod 7 else to_int s in
               tu.(tn - 1 + i - n + 1) * s)
             a)
  in
  aux

(** Give the index of the first non-None value in the list. *)
let last_index l =
  let rec last_index n = function
    | x :: tl -> if x = None then last_index (n + 1) tl else n
    | [] -> n
  in
  last_index 0 l

(** Give the precision of a date-as-list.
    For example, the precision of Xs is 1, XmYs is 60, XhYmZs 3600, etc. *)
let precision d = time_units.(last_index d)

(** Give the duration of a data-as-list.
    For example, the duration of Xs is 1, Xm 60, XhYm 60, etc. *)
let duration d =
  time_units.(Array.length time_units - 1 - last_index (List.rev d))

let between ~pos d1 d2 =
  let p1 = precision d1 in
  let p2 = precision d2 in
  let t1 = date ~pos d1 in
  let t2 = date ~pos d2 in
  if p1 <> p2 then
    raise (Parse_error (pos, "Invalid time interval: precisions differ."));
  (t1, t2, p1)

let during ~pos d =
  let t, d, p = (date ~pos d, duration d, precision d) in
  (t, t + d, p)

let mk_time_pred ~pos (a, b, c) =
  let args = List.map (fun x -> ("", mk ~pos (Ground (Int x)))) [a; b; c] in
  mk ~pos (App (mk ~pos (Var "time_in_mod"), args))

let mk_kind ~pos (kind, params) =
  if kind = "any" then Type.var ~pos ()
  else (
    try
      let k = Frame_content.kind_of_string kind in
      match params with
        | [] -> Term.kind_t (`Kind k)
        | [("", "any")] -> Type.var ()
        | [("", "internal")] -> Type.var ~constraints:[Type.InternalMedia] ()
        | param :: params ->
            let mk_format (label, value) =
              Frame_content.parse_param k label value
            in
            let f = mk_format param in
            List.iter
              (fun param -> Frame_content.merge f (mk_format param))
              params;
            assert (k = Frame_content.kind f);
            Term.kind_t (`Format f)
    with _ ->
      let params =
        params |> List.map (fun (l, v) -> l ^ "=" ^ v) |> String.concat ","
      in
      let t = kind ^ "(" ^ params ^ ")" in
      raise (Parse_error (pos, "Unknown type constructor: " ^ t ^ ".")))

let mk_source_ty ~pos name args =
  if name <> "source" then
    raise (Parse_error (pos, "Unknown type constructor: " ^ name ^ "."));

  let audio = ref ("any", []) in
  let video = ref ("any", []) in
  let midi = ref ("any", []) in

  List.iter
    (function
      | "audio", k -> audio := k
      | "video", k -> video := k
      | "midi", k -> midi := k
      | l, _ ->
          raise (Parse_error (pos, "Unknown type constructor: " ^ l ^ ".")))
    args;

  let audio = mk_kind ~pos !audio in
  let video = mk_kind ~pos !video in
  let midi = mk_kind ~pos !midi in

  Term.source_t (Term.frame_kind_t audio video midi)

let mk_ty ~pos name =
  match name with
    | "_" -> Type.var ()
    | "unit" -> Type.make Type.unit
    | "bool" -> Type.make (Type.Ground Type.Bool)
    | "int" -> Type.make (Type.Ground Type.Int)
    | "float" -> Type.make (Type.Ground Type.Float)
    | "string" -> Type.make (Type.Ground Type.String)
    | "source" -> mk_source_ty ~pos "source" []
    | "source_methods" -> !Term.source_methods_t ()
    | name -> (
        match Type.resolve_ground_opt name with
          | Some g -> Type.make (Type.Ground g)
          | None ->
              raise
                (Parse_error (pos, "Unknown type constructor: " ^ name ^ ".")))
