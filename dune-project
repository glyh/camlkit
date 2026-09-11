(lang dune 3.20)
(name camlkit)
(generate_opam_files true)
(source
 (github glyh/camlkit))

(authors "Yihang Liu")

(maintainers "Yihang Liu")

(license MIT)

(package
 (name camlkit)
 (synopsis "MCP server giving an agent OCaml toplevels, source queries and builds")
 (description
  "Gives an MCP client one or more live OCaml toplevels, merlin-backed\nsource queries and a dune build. A worker process owns the toplevel over\ncompiler-libs; the server supervises one worker per session and speaks MCP\nover stdio.")
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
  (alcotest (and (>= 1.7) :with-test))
  ; Only to exercise the Lwt half of auto-run; nothing links against it.
  (lwt :with-test)))
