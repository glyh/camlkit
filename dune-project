(lang dune 3.20)
(name utop-mcp)
(generate_opam_files true)
(source
 (github glyh/utop-mcp))

(authors "Yihang Liu")

(maintainers "Yihang Liu")

(license MIT)

(package
 (name utop-mcp)
 (synopsis "MCP server exposing an OCaml utop toplevel")
 (description
  "Gives an MCP client one or more live OCaml toplevels. A worker process\nlinks the utop library and owns the toplevel; the server supervises one\nworker per session and speaks MCP over stdio.")
 (depends
  (ocaml (>= 5.3.0))
  (jsonrpc (>= 1.20))
  (utop (>= 2.16))
  (yojson (>= 2.0))
  (alcotest (and (>= 1.7) :with-test))))
