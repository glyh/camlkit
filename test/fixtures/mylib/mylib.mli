(* A findlib package carrying an automatic toplevel printer, so the test can
   tell whether we install it the way utop does. *)
type t
val make : int -> t
val pp : Format.formatter -> t -> unit
[@@ocaml.toplevel_printer]
