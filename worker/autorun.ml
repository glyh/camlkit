(* Running Lwt and Async expressions instead of handing back a promise.

   Typing `Lwt_io.printl "hi"` at a toplevel otherwise yields a `unit Lwt.t`
   that nobody has run. utop rewrites such an expression into
   `Lwt_main.run (...)`, and the Async equivalent into
   `Async.Thread_safe.block_on_async_exn (fun () -> ...)`. This does the same.

   Each rule also self-gates: it fires only when the expression's type is the
   one it rewrites *and* the function that would run it exists in the
   environment, so a session that has never loaded Lwt is unaffected whatever
   the mode. The mode is there for the case where a caller wants the promise
   back even though the library is loaded.

   Order matters. This must run before bare expressions are given implicit
   names, because after that rewrite a phrase is a `let`, not a `Pstr_eval`,
   and there is nothing left to match. utop sequences them the same way. *)

let longident parts =
  match Longident.unflatten parts with
  | Some l -> l
  | None -> invalid_arg "Autorun.longident"

type rule =
  { name : string                    (* what a caller enables it by *)
  ; type_name : Longident.t          (* the type whose values get run *)
  ; runner : Longident.t             (* the function that runs one *)
  ; wrap : Location.t -> Parsetree.expression -> Parsetree.expression
  }

let rules =
  [ { name = "lwt"
    ; type_name = longident [ "Lwt"; "t" ]
    ; runner = longident [ "Lwt_main"; "run" ]
    ; wrap =
        (fun loc e ->
           Ast_helper.with_default_loc loc (fun () ->
               Ast_helper.Exp.apply
                 (Ast_helper.Exp.ident
                    { Asttypes.txt = longident [ "Lwt_main"; "run" ]; loc })
                 [ (Asttypes.Nolabel, e) ]))
    }
  ; { name = "async"
    ; type_name = longident [ "Async"; "Deferred"; "t" ]
    ; runner = longident [ "Async"; "Thread_safe"; "block_on_async_exn" ]
      (* Async needs a thunk: its runner starts the scheduler around the work
         rather than waiting on an already-running deferred. *)
    ; wrap =
        (fun loc e ->
           Ast_helper.with_default_loc loc (fun () ->
               let unit_pat =
                 Ast_helper.Pat.construct
                   { Asttypes.txt = Longident.Lident "()"; loc } None
               in
               (* Parsetree's function form, not Exp.fun_: the latter went
                  away in 5.2, below this project's floor, so no version
                  branch is needed here. *)
               let thunk =
                 Ast_helper.Exp.function_
                   [ { Parsetree.pparam_loc = loc
                     ; pparam_desc =
                         Parsetree.Pparam_val (Asttypes.Nolabel, None, unit_pat)
                     } ]
                   None
                   (Parsetree.Pfunction_body e)
               in
               Ast_helper.Exp.apply
                 (Ast_helper.Exp.ident
                    { Asttypes.txt =
                        longident [ "Async"; "Thread_safe"; "block_on_async_exn" ]
                    ; loc })
                 [ (Asttypes.Nolabel, thunk) ]))
    }
  ]

(* Which rewrites this session performs, by name. A list rather than an enum
   so another rule can be added without changing the shape callers pass.

   utop performs both unconditionally, and the self-gating below makes that
   inert in a session that has loaded neither library, so that is the default.
   Emptying the list is how a caller keeps the promise itself, which is a
   legitimate thing to want in code that manipulates them. *)
(* Per call, not per session. It was a session setting, which made one
   argument mean three things - leave it alone, set it, turn it off - and made
   the answer to "will this run my promise" depend on a call the caller may
   not remember making. A call says what it wants or takes the default; see
   docs/wayfinder/tickets/019. *)
let default = Wire.Msg.autorun_default
let available = List.map (fun r -> r.name) rules

(* Unknown names are refused rather than ignored: a caller that asks for a
   rewrite this does not have should hear so, not silently get nothing. *)
let check names =
  match List.filter (fun n -> not (List.mem n available)) names with
  | [] -> Ok ()
  | unknown ->
    Error
      (Printf.sprintf "no such autorun rule: %s. Known rules: %s"
         (String.concat ", " unknown) (String.concat ", " available))

let type_path env name =
  match Env.find_type_by_name name env with
  | path, _ -> Some path
  | exception Not_found -> None

let runner_available env name =
  match Env.find_value_by_name name env with
  | _ -> true
  | exception Not_found -> false

(* The head type constructor of an expression, after expanding aliases. *)
let head_constructor env ty =
  match Types.get_desc (Ctype.expand_head env ty) with
  | Types.Tconstr (path, _, _) -> Some path
  | _ -> None

let rule_for ~enabled env ty =
  match head_constructor env ty with
  | None -> None
  | Some path ->
    List.find_opt
      (fun rule ->
         List.mem rule.name enabled
         &&
         match type_path env rule.type_name with
         | Some p -> Path.same path p && runner_available env rule.runner
         | None -> false)
      rules

(* Rewrites the bare expressions of a structure whose types call for it, using
   the typed structure to know what those types are. Also reports which rule
   fired, if any, because the rewrite is otherwise invisible in the result:
   a run promise renders exactly like the value it produced. *)
let rewrite ~enabled env (pstr : Parsetree.structure) (tstr : Typedtree.structure) =
  if enabled = [] then (pstr, None) else
  let fired = ref None in
  let rewrite_item item titem =
    match item.Parsetree.pstr_desc, titem.Typedtree.str_desc with
    | ( Parsetree.Pstr_eval (e, attrs)
      , Typedtree.Tstr_eval ({ Typedtree.exp_type; _ }, _) ) ->
      (match rule_for ~enabled env exp_type with
       | None -> item
       | Some rule ->
         if !fired = None then fired := Some rule.name;
         { item with
           Parsetree.pstr_desc =
             Parsetree.Pstr_eval (rule.wrap item.Parsetree.pstr_loc e, attrs)
         })
    | _ -> item
  in
  let titems = tstr.Typedtree.str_items in
  if List.length pstr <> List.length titems then (pstr, None)
  else
    let rewritten = List.map2 rewrite_item pstr titems in
    (rewritten, !fired)
