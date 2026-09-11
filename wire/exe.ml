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
