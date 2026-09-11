(* The toplevel's stdout and stderr are redirected onto a file we own.
   A file rather than a pipe: a phrase that outruns a draining reader would
   fill a pipe buffer and block the toplevel mid-evaluation. A file has no
   buffer to fill, and reading by offset is exact.
   Truncated at the start of each eval so it does not grow across a session. *)

type t = { fd : Unix.file_descr; path : string }

let create () =
  let path = Filename.temp_file "utop-mcp-" ".out" in
  let fd = Unix.openfile path [ Unix.O_RDWR ] 0o600 in
  (* Unlinked immediately: the fd keeps it alive, and it cannot outlive us. *)
  Unix.unlink path;
  Unix.dup2 fd Unix.stdout;
  Unix.dup2 fd Unix.stderr;
  { fd; path }

let reset t =
  flush Stdlib.stdout; flush Stdlib.stderr;
  Unix.ftruncate t.fd 0;
  ignore (Unix.lseek t.fd 0 Unix.SEEK_SET)

(* Bytes written so far. Taken after each phrase to give that phrase's span. *)
let mark t = flush Stdlib.stdout; flush Stdlib.stderr; (Unix.fstat t.fd).Unix.st_size

let contents t =
  let len = mark t in
  let b = Bytes.create len in
  ignore (Unix.lseek t.fd 0 Unix.SEEK_SET);
  let n = Unix.read t.fd b 0 len in
  ignore (Unix.lseek t.fd 0 Unix.SEEK_END);
  Bytes.sub_string b 0 n
