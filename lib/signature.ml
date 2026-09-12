(* The signature of a module, value or type in an installed findlib package,
   without loading it into a session.

   `describe` answers from a live toplevel, so it only sees what a session has
   already required; asking what is in a package means loading it first, which
   links its archives and runs its initialisers. This answers from the
   compiled interfaces alone: #directory adds a search path and #show reads
   .cmi files, so nothing is linked and nothing runs.

   Shelled out to the switch's own toplevel rather than reading the .cmi here.
   #show already resolves a dotted path, prints every kind of item, and is
   locked to the compiler that wrote the interface; reading interfaces
   ourselves would mean linking compiler-libs into the native server and
   reimplementing both halves. Same reasoning as merlin in lib/merlin.ml. *)

let run cmd script =
  let out, inp = Unix.open_process cmd in
  (try output_string inp script with Sys_error _ -> ());
  (try close_out inp with Sys_error _ -> ());
  let buf = Buffer.create 4096 in
  (try
     let chunk = Bytes.create 65536 in
     let rec go () =
       match input out chunk 0 (Bytes.length chunk) with
       | 0 -> ()
       | n -> Buffer.add_subbytes buf chunk 0 n; go ()
     in
     go ()
   with End_of_file -> ());
  let status = Unix.close_process (out, inp) in
  (String.trim (Buffer.contents buf), status)

(* Recursive: a signature names types from the package's dependencies, and
   #show cannot print what it cannot find. *)
let directories package =
  let cmd =
    Printf.sprintf "%s query -r -format %%d %s 2>&1"
      (Filename.quote (Wire.Exe.find "ocamlfind")) (Filename.quote package)
  in
  match run cmd "" with
  | out, Unix.WEXITED 0 ->
    Ok (List.filter (fun d -> d <> "") (String.split_on_char '\n' out))
  | out, _ -> Error (if out = "" then "ocamlfind failed" else out)

(* The path is spliced into a toplevel script, so it must not be able to end
   the phrase and begin another. Every character an OCaml path can hold is
   allowed, including the parentheses around an operator. *)
let is_a_path s =
  s <> ""
  && not (String.exists
            (fun c -> c = ';' || c = '"' || c = '\\' || c = '\n' || c = '\r') s)

(* Most packages are named after their top module, so guessing saves the
   caller a lookup; a package that is not says so and can be named outright. *)
let package_of path =
  match String.index_opt path '.' with
  | Some i -> String.lowercase_ascii (String.sub path 0 i)
  | None -> String.lowercase_ascii path

let show ~package ~path =
  if not (is_a_path path) then Error (Printf.sprintf "%S is not an OCaml path" path)
  else
    match directories package with
    | Error e -> Error e
    | Ok [] ->
      Error (Printf.sprintf "findlib gave package %S no directory" package)
    | Ok dirs ->
      let script =
        String.concat ""
          (List.map (fun d -> Printf.sprintf "#directory %S;;\n" d) dirs)
        ^ Printf.sprintf "#show %s;;\n" path
      in
      let cmd =
        Printf.sprintf "%s -noinit -no-version -noprompt 2>&1"
          (Filename.quote (Wire.Exe.find "ocaml"))
      in
      match run cmd script with
      | "", _ ->
        Error
          (Printf.sprintf
             "the toplevel produced no answer. `ocaml` is a runtime \
              dependency and must be installed in the same opam switch as \
              this server.")
      (* What #show prints for a name it cannot resolve, whichever component
         of the path is missing. *)
      | out, _ when out = "Unknown element." ->
        Error (Printf.sprintf "no %s in package %s" path package)
      | out, _ -> Ok out
