(* Finding the binaries we shell out to.

   Beside our own executable before PATH: we are installed into an opam switch
   where dune and ocamlmerlin live, and a client may spawn us with an
   environment that has neither on PATH. Shared because the server looks up
   ocamlmerlin and the worker looks up dune, for the same reason. *)

let find name =
  let beside = Filename.concat (Filename.dirname Sys.executable_name) name in
  if Sys.file_exists beside then beside else name

(* The directory holding dune-project, walking up from a file. None when the
   path is not inside a dune project. *)
let project_root_of path =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir "dune-project") then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else up parent
  in
  up (if Sys.is_directory path then path else Filename.dirname path)

(* The switch these binaries were installed into, and the environment a child
   process needs in order to work inside it.

   A client spawns the server from whatever shell it has, which is usually one
   without `opam env`. dune then cannot resolve a project's packages - it
   reports `Library "yojson" not found` and the loader silently falls back to
   scanning - and ocamlmerlin's index build fails the same way. See
   docs/wayfinder/tickets/039.

   Derived from our own path rather than by running `opam env`, for three
   reasons. `opam` is not installed into the switch, so it may not be there to
   run. It costs a subprocess on a path that already shells out. And without
   `--switch` it answers for the shell's switch, which is exactly the switch
   that is wrong: what matters is the one these binaries were installed into,
   because bytecode is version-locked to the compiler that built it. *)

(* Set this to a switch prefix to use another switch's dune, merlin and
   packages. Only sound when that switch has the same OCaml version, since the
   worker is bytecode from this one.

   Set it to "none" (or empty) to adopt nothing and inherit the environment as
   given, which is what a project built with nix rather than opam wants: there
   the toolchain is already on PATH and a store path is not a switch to
   prepend. Both spellings, because an empty value is what a shell produces by
   accident from an unset variable and "none" is what someone writes on
   purpose. *)
let switch_override = "CAMLKIT_SWITCH"

(* A real switch has its stdlib here. In a dune build tree the derived prefix
   is `_build/default`, which does not, and adopting it would be nonsense -
   development already runs under `opam env`. *)
let is_switch prefix = Sys.file_exists (Filename.concat prefix "lib/ocaml")

let switch_prefix () =
  match Sys.getenv_opt switch_override with
  | Some ("" | "none") -> None
  | Some p when is_switch p -> Some p
  | Some p ->
    prerr_endline
      (Printf.sprintf
         "camlkit: %s=%s is not a switch (no lib/ocaml under it); ignoring it"
         switch_override p);
    None
  | None ->
    let prefix = Filename.dirname (Filename.dirname Sys.executable_name) in
    if is_switch prefix then Some prefix else None

(* Two of what `opam env` sets, and deliberately not the rest. Pure, so the
   shape can be checked without touching the process environment.

   PATH is the one that was measured to fix it: dune finds ocamlfind through
   it, and nothing else was needed. OPAM_SWITCH_PREFIX says which switch this
   is, for any tool that asks.

   `CAML_LD_LIBRARY_PATH` is deliberately absent, and this is where it would
   have gone. [C stubs in a bare environment](docs/wayfinder/tickets/028)
   decided not to set that variable, because a user may have set it
   deliberately, and reached the same end through `Dll.add_path` inside the
   worker instead. Setting it here would overrule that decision and would not
   help the worker anyway: the runtime reads it when the process starts, so a
   putenv afterwards is too late for this process and only reaches children,
   which do not load our stubs. The toplevel path variables are absent for the
   same kind of reason - the only toplevel here is the one inside the worker,
   which is configured through findlib rather than through the environment. *)
let switch_vars prefix = [ "OPAM_SWITCH_PREFIX", prefix ]

(* Prepended, so this switch wins over whatever the client's shell had: these
   binaries only work with their own. Idempotent, so a re-exec does not grow
   the variable. *)
let path_with ~bin existing =
  match existing with
  | None | Some "" -> bin
  | Some p ->
    let parts = String.split_on_char ':' p in
    if List.exists (fun d -> d = bin) parts then p else bin ^ ":" ^ p

(* Called once at startup by both processes: children inherit it, which is the
   whole point, and there is no call site left to forget. *)
let adopt_switch () =
  match switch_prefix () with
  | None -> ()
  | Some prefix ->
    List.iter (fun (k, v) -> Unix.putenv k v) (switch_vars prefix);
    Unix.putenv "PATH"
      (path_with ~bin:(Filename.concat prefix "bin") (Sys.getenv_opt "PATH"))

(* OCAMLPARAM with [ours] applied after whatever the user already set there,
   rather than in place of it: load builds through this variable (see
   docs/wayfinder/tickets/054 and 060). Pure, so the merge is checkable without
   an environment.

   Read the way driver/compenv.ml reads it: a leading `:`, `|`, `;`, space or
   comma chooses the separator, and exactly one `_` splits the settings applied
   before the command line from those applied after. A value the compiler
   refuses it also ignores whole, after saying so, so nothing of one is kept
   here either. Ours go last, after the `_`, so `w=-a` has the final word.

   The separator is chosen rather than fixed, because a ppx setting carries a
   path, and a comma in the path would otherwise split it. Error only when every
   separator the compiler allows occurs in some setting. *)
let ocamlparam ~ours existing =
  let args s =
    if s = "" then []
    else match s.[0] with
      | (':' | '|' | ';' | ' ' | ',') as c -> List.tl (String.split_on_char c s)
      | _ -> String.split_on_char ',' s
  in
  let theirs =
    match existing with
    | None -> []
    | Some s ->
      let a = List.filter (fun x -> x <> "") (args s) in
      if List.length (List.filter (fun x -> x = "_") a) = 1 then a else []
  in
  let all = (if theirs = [] then [ "_" ] else theirs) @ ours in
  let free c = List.for_all (fun a -> not (String.contains a c)) all in
  match List.find_opt free [ ','; '|'; ';'; ':' ] with
  | Some ',' -> Ok (String.concat "," all)
  | Some c -> let sep = String.make 1 c in Ok (sep ^ String.concat sep all)
  | None ->
    Error
      (Printf.sprintf
         "OCAMLPARAM cannot carry these settings: each of , | ; : occurs in one \
          of them, and the compiler allows no other separator: %s"
         (String.concat " " all))
