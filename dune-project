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
  ; A runtime dependency on a binary rather than a library: the source-query
  ; tools shell out to ocamlmerlin, which is looked up beside our own
  ; executable first and so must live in the same switch. Nothing links
  ; against merlin, and no version is pinned because merlin's own versions
  ; track the compiler. The other binary dependency, dune, comes in above.
  merlin
  (ocamlfind (>= 1.9))
  (yojson (>= 2.0))
  (alcotest (and (>= 1.7) :with-test))))
