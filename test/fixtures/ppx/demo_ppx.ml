(* A real ppx for the suite, so an expansion is tested against a deriver an
   agent would actually meet rather than against a rewriter written to pass.
   ppx_deriving.show is the case ticket 037 is about: nothing in
   `[@@deriving show]` tells a reader that it produces `pp` and `show`.

   Built as a standalone driver rather than reached through dune's
   `(preprocess (pps ...))`, because merlin inside `dune test` would have to
   ask dune for the file's configuration and dune will not run inside dune -
   the same wall `load` is behind. The driver answers the compiler's own -ppx
   protocol under `--as-ppx`, which a `.merlin` can name directly. *)
let () = Ppxlib.Driver.standalone ()
