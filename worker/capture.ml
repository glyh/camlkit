(* The toplevel's stdout and stderr are redirected onto a file the server
   named, so the server can read partial output at any time and recover
   whatever a phrase printed before it had to be killed.

   A file rather than a pipe: a phrase that outruns a draining reader would
   fill a pipe buffer and block the toplevel mid-evaluation. A file has no
   buffer to fill, and reading by offset is exact.

   Truncated at the start of each eval, so it holds exactly the current
   evaluation and does not grow across a session. The server owns the file's
   lifetime, since it outlives us by design. *)

type t = { fd : Unix.file_descr }

let create path =
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 fd Unix.stdout;
  Unix.dup2 fd Unix.stderr;
  { fd }

let reset t =
  flush Stdlib.stdout; flush Stdlib.stderr;
  Unix.ftruncate t.fd 0;
  ignore (Unix.lseek t.fd 0 Unix.SEEK_SET)

(* Bytes written so far. Taken after each phrase to give that phrase's span. *)
let mark t = flush Stdlib.stdout; flush Stdlib.stderr; (Unix.fstat t.fd).Unix.st_size

(* Read in a loop. Unix.read copies through a fixed internal buffer and returns
   at most 64K per call, so a single read silently lost everything a phrase
   printed beyond that, while reporting no truncation at all. *)
let contents ?limit t =
  let available = mark t in
  let len = match limit with Some l -> min l available | None -> available in
  let b = Bytes.create len in
  ignore (Unix.lseek t.fd 0 Unix.SEEK_SET);
  let rec fill got =
    if got >= len then got
    else
      match Unix.read t.fd b got (len - got) with
      | 0 -> got
      | n -> fill (got + n)
  in
  let got = fill 0 in
  ignore (Unix.lseek t.fd 0 Unix.SEEK_END);
  (Bytes.sub_string b 0 got, available > got)
