(lang dune 3.20)
(name utop-mcp)
(generate_opam_files true)
(package
 (name utop-mcp)
 (synopsis "MCP server exposing an OCaml utop toplevel")
 (depends
  (ocaml (>= 5.3.0))
  (jsonrpc (>= 1.20))
  (utop (>= 2.16))
  (yojson (>= 2.0))
  (alcotest (and (>= 1.7) :with-test))))
