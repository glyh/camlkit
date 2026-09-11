(lang dune 3.20)
(name utop_mcp)
(generate_opam_files true)
(package
 (name utop_mcp)
 (synopsis "MCP server exposing an OCaml utop toplevel")
 (depends
  (ocaml (>= 5.0))
  (eio_main (>= 1.0))
  (jsonrpc (>= 1.20))
  (yojson (>= 2.0))
  (alcotest (and (>= 1.7) :with-test))))
