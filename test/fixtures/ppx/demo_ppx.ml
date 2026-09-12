(* A ppx for the test suite, over compiler-libs alone so it adds no dependency.
   [%demo] becomes a multi-line expression, which is what makes it useful here:
   it shows that expand returns source to read rather than JSON with every
   newline escaped.

   Deliberately not a dune `pps` rewriter. dune's pps requires a ppxlib-style
   driver and refuses this outright - "No ppx driver were found" - so the suite
   reaches it the way the compiler does, through the -ppx protocol that
   Ast_mapper.run_main implements, named in a .merlin the test writes. See
   docs/wayfinder/tickets/037. *)
open Ast_mapper
open Parsetree

let generated loc =
  (* Several lines, and a name a reader could not have guessed from the call
     site, which is the whole point of asking what a ppx generated. *)
  let open Ast_helper in
  with_default_loc loc (fun () ->
      Exp.let_ Asttypes.Nonrecursive
        [ Vb.mk (Pat.var { Asttypes.txt = "demo_generated_name"; loc })
            (Exp.constant (Const.int 42)) ]
        (Exp.ident { Asttypes.txt = Longident.Lident "demo_generated_name"; loc }))

let expr mapper e =
  match e.pexp_desc with
  | Pexp_extension ({ Asttypes.txt = "demo"; _ }, PStr []) -> generated e.pexp_loc
  | _ -> default_mapper.expr mapper e

let () = register "demo_ppx" (fun _ -> { default_mapper with expr })
