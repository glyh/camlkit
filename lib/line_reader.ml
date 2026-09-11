(* Functional core: splitting a byte stream into newline-delimited messages.
   MCP over stdio is one JSON object per line, and a readable descriptor does
   not imply a complete line, so the remainder is carried forward. *)

(* Complete lines, then whatever is left over. *)
let split s =
  let rec go acc start i =
    if i >= String.length s then (List.rev acc, String.sub s start (i - start))
    else if s.[i] = '\n' then
      let line = String.sub s start (i - start) in
      (* tolerate CRLF *)
      let line =
        let n = String.length line in
        if n > 0 && line.[n - 1] = '\r' then String.sub line 0 (n - 1) else line
      in
      go (line :: acc) (i + 1) (i + 1)
    else go acc start (i + 1)
  in
  go [] 0 0
