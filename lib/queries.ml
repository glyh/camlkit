(* The tools that need no session: merlin's source queries, an installed
   package's signatures, and a file's context. Declared from their types, see
   docs/wayfinder/tickets/071. Each answers inside the call. *)

type file_args = {
  file : string;
  (** Absolute path to a source file. *)
} [@@deriving mcp]

type at_args = {
  file : string;
  (** Absolute path to a source file. *)
  line : int;
  (** 1-based. *)
  col : int;
  (** 0-based. *)
} [@@deriving mcp]

let ( let* ) = Result.bind
let fail r = Result.map_error (fun e -> Tool.failure e) r

let query ?source ~command ~args ~file () =
  fail (Merlin.query ?source ~command ~args ~file ())

let at (a : at_args) = [ "-position"; Merlin.position a.line a.col ]

let read_only = Tool.make ~read_only:true ~idempotent:true ~open_world:false

(* --- outline ------------------------------------------------------------ *)

type outline_result = { items : Merlin.outline_item list } [@@deriving mcp]

let outline =
  read_only ~name:"outline"
    ~doc:"List what a source file defines, cheaper than reading it."
    file_args_mcp outline_result_mcp
    (fun { file } ->
       let* v = query ~command:"outline" ~args:[] ~file () in
       let* items = fail (Merlin.list Merlin.outline_item_mcp v) in
       Ok { items = Merlin.in_source_order items })

(* --- locate ------------------------------------------------------------- *)

type locate_result = {
  location : Merlin.location option;
  error : string;
  (** Why there is no location: no name at the position, or merlin could not
      find its definition. *)
} [@@deriving mcp]

let locate =
  read_only ~name:"locate"
    ~doc:"Find where the name at a position is defined. No build or session."
    at_args_mcp locate_result_mcp
    (fun a ->
       let* v = query ~command:"locate" ~args:(at a) ~file:a.file () in
       match v with
       (* A location is an object; every failure is a bare string under the
          same success class. See tickets/063. *)
       | `String error -> Ok { location = None; error }
       | v ->
         let* l = fail (Merlin.decode Merlin.location_mcp v) in
         Ok { location = Some l; error = "" })

(* --- type_at ------------------------------------------------------------ *)

type type_at_result = { enclosings : Merlin.enclosing list } [@@deriving mcp]

let type_at =
  read_only ~name:"type_at"
    ~doc:"The type at a position and of each enclosing expression. No build or \
          session."
    at_args_mcp type_at_result_mcp
    (fun a ->
       let* v = query ~command:"type-enclosing" ~args:(at a) ~file:a.file () in
       let* es = fail (Merlin.list Merlin.enclosing_mcp v) in
       Ok { enclosings = Merlin.dedup (List.map Merlin.enclosing_tail es) })

(* --- uses --------------------------------------------------------------- *)

type uses_args = {
  file : string;
  (** Absolute path to a source file. *)
  line : int;
  (** 1-based. *)
  col : int;
  (** 0-based. *)
  scope : string; [@default "project"]
  (** project or buffer. *)
} [@@deriving mcp]

type uses_result = {
  occurrences : Merlin.occurrence list;
  incomplete : bool;
  (** Occurrences in this file only, because dune's index was not available. *)
  caveat : string;
  (** Why the answer is incomplete, and what would fix it. *)
} [@@deriving mcp]

let uses =
  Tool.make ~name:"uses" ~idempotent:true ~destructive:false ~open_world:false
    ~doc:"Every occurrence of the name at a position, project-wide by default."
    uses_args_mcp uses_result_mcp
    (fun a ->
       (* Project scope is silently buffer scope without dune's index, so build
          it first rather than return a complete-looking partial answer. *)
       let index = if a.scope = "project" then Merlin.ensure_index a.file else Ok () in
       let* v =
         query ~command:"occurrences" ~file:a.file ()
           ~args:[ "-identifier-at"; Merlin.position a.line a.col; "-scope"; a.scope ] in
       let* occurrences = fail (Merlin.list Merlin.occurrence_mcp v) in
       Ok (match index with
           | Ok () -> { occurrences; incomplete = false; caveat = "" }
           | Error why ->
             (* Two reasons reach this, so the sentence cannot claim either:
                dune failed, or it wrote no index because the project's
                compiler writes no occurrence data. See tickets/046. *)
             { occurrences; incomplete = true;
               caveat =
                 Printf.sprintf
                   "these are occurrences in this file only. Project-wide \
                    results need dune's index, which is not available here \
                    (%s). Where the project is a dune project on OCaml 5.2 or \
                    later, `dune build @ocaml-index` in it and asking again \
                    fixes this." why }))

(* --- search_type -------------------------------------------------------- *)

type search_type_args = {
  file : string;
  (** Absolute path to a source file. *)
  line : int;
  (** 1-based. *)
  col : int;
  (** 0-based. *)
  query : string;
  limit : int option;
} [@@deriving mcp]

type search_type_result = { results : Merlin.search_hit list } [@@deriving mcp]

let search_type =
  read_only ~name:"search_type"
    ~doc:"Find values by type, such as 'a list -> 'a option. Qualify type names: \
          Core.term, not term."
    search_type_args_mcp search_type_result_mcp
    (fun a ->
       (* Twice the limit, because repeats are dropped below and a limit should
          count what the caller gets. *)
       let limit = match a.limit with
         | Some n when n > 0 -> [ "-limit"; string_of_int (n * 2) ] | _ -> [] in
       let* v =
         query ~command:"search-by-type" ~file:a.file ()
           ~args:(at { file = a.file; line = a.line; col = a.col }
                  @ [ "-query"; a.query ] @ limit) in
       let* hits = fail (Merlin.list Merlin.search_hit_mcp v) in
       let resolve name half =
         (* Not the caller's position: see Merlin.neutral_position. *)
         match Merlin.query ~command:"locate" ~file:a.file ()
                 ~args:[ "-position"; Merlin.neutral_position;
                         "-prefix"; name; "-look-for"; half ] with
         | Ok (`Assoc _ as v) -> Yojson.Safe.Util.(member "file" v |> to_string_option)
         | _ -> None
       in
       let hits = Merlin.dedup (Merlin.with_paths ~resolve hits) in
       let hits = match a.limit with
         | Some n when n > 0 -> List.filteri (fun i _ -> i < n) hits
         | _ -> hits in
       Ok { results = hits })

(* --- expand ------------------------------------------------------------- *)

type expand_result = {
  code : string;
  deriver : Merlin.span option;
  (** The range of the deriver or extension node the code came from. *)
  error : string;
} [@@deriving mcp]

let expand =
  read_only ~name:"expand"
    ~doc:"Show the code a ppx generates. Put the position on the deriver name or \
          the [%extension], not on what it is attached to."
    at_args_mcp expand_result_mcp
    (fun a ->
       let* v = query ~command:"expand-ppx" ~args:(at a) ~file:a.file () in
       let* e = fail (Merlin.expansion v) in
       Ok (match e with
           | Ok (code, deriver) -> { code; deriver; error = "" }
           (* No ppx at that position is an answer about the file. *)
           | Error error -> { code = ""; deriver = None; error }))

(* --- diagnostics -------------------------------------------------------- *)

type diagnostics_args = {
  file : string;
  (** Absolute path to a source file. *)
  source : string option;
  (** Contents to check instead of the file. *)
} [@@deriving mcp]

type diagnostics_result = {
  errors : Merlin.diagnostic list;
  warnings : Merlin.diagnostic list;
} [@@deriving mcp]

let diagnostics =
  read_only ~name:"diagnostics"
    ~doc:"A file's errors and warnings in milliseconds, or an unwritten edit's. \
          Not a build."
    diagnostics_args_mcp diagnostics_result_mcp
    (fun { file; source } ->
       (* The file is still named when there is an edit, because that is how
          merlin finds the configuration to type it against. *)
       let* v = query ?source ~command:"errors" ~args:[] ~file () in
       let* errors, warnings = fail (Merlin.diagnostics v) in
       Ok { errors; warnings })

(* --- document ----------------------------------------------------------- *)

type document_args = {
  file : string;
  (** Absolute path to a source file. *)
  identifier : string option;
  (** A name in scope in that file. *)
  line : int option;
  (** 1-based. *)
  col : int option;
  (** 0-based. *)
} [@@deriving mcp]

type document_result = {
  documentation : string;
  error : string;
} [@@deriving mcp]

let document =
  read_only ~name:"document"
    ~doc:"A name's documentation comment. Give identifier, or line and col, not \
          both."
    document_args_mcp document_result_mcp
    (fun a ->
       (* The schema cannot say these are exclusive, so the check is here: both
          would silently ignore the position. *)
       let* args =
         match a.identifier, a.line, a.col with
         | Some i, None, None ->
           (* Not the caller's position: see Merlin.neutral_position. *)
           Ok [ "-position"; Merlin.neutral_position; "-identifier"; i ]
         | None, Some l, Some c -> Ok [ "-position"; Merlin.position l c ]
         | Some _, _, _ ->
           Error (Tool.failure
                    "give identifier, or line and col, not both: an identifier is \
                     looked up in the file's environment and needs no position")
         | None, _, _ ->
           Error (Tool.failure
                    "give identifier for a name in scope in that file, or line and \
                     col for whatever is at that position")
       in
       let* v = query ~command:"document" ~args ~file:a.file () in
       Ok (match Merlin.documentation v with
           | Ok documentation -> { documentation; error = "" }
           (* A name with no comment on it is an answer. *)
           | Error error -> { documentation = ""; error }))

(* --- signature ---------------------------------------------------------- *)

type signature_args = {
  path : string;
  (** Such as Lwt.Infix. *)
  package : string option;
  (** Omit when named after the path's first module. *)
} [@@deriving mcp]

type signature_result = {
  signature : string;
  package : string;
  guessed : bool;
  (** The package was guessed from the path; name it if the guess was wrong. *)
  error : string;
} [@@deriving mcp]

let signature =
  read_only ~name:"signature"
    ~doc:"Browse an installed findlib package's signatures, with no session."
    signature_args_mcp signature_result_mcp
    (fun { path; package } ->
       let guessed = package = None in
       let package = Option.value package ~default:(Signature.package_of path) in
       (* A package or a path that is not there is a negative answer. *)
       Ok (match Signature.show ~package ~path with
           | Ok signature -> { signature; package; guessed; error = "" }
           | Error error -> { signature = ""; package; guessed; error }))

(* --- context ------------------------------------------------------------ *)

type context_result = {
  opens : string list option;
  (** The modules to open, in order; [] when a session needs none. *)
  error : string;
} [@@deriving mcp]

let context =
  read_only ~name:"context"
    ~doc:"The opens that let a session read a fragment of a file the way the file \
          does."
    file_args_mcp context_result_mcp
    (fun { file } ->
       Ok (match Context.of_file ~file with
           (* A file merlin cannot read or configure is an answer about it. *)
           | Error error -> { opens = None; error }
           | Ok opens -> { opens = Some opens; error = "" }))

let all =
  [ outline; locate; type_at; uses; search_type; expand; diagnostics; document;
    signature; context ]
