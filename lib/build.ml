(* Building a dune project.

   This shells out to `dune build` rather than driving dune's RPC. RPC would
   carry diagnostics as data, and that was tried: connecting, handshaking and
   reading diagnostics all work, but four separate obstacles surfaced on the
   way and a fifth stopped it. The `dune rpc` command reports no diagnostics at
   all; the one published hand-rolled client does not handshake with dune 3.24;
   dune's client functor deadlocks unless its fiber is a deferred computation
   rather than a value; the public API has no build request, so dune's private
   one has to be declared by hand; and with all of that done, the build request
   itself hangs. The whole mechanism is marked Experimental by dune.

   `dune build` needs no watcher, no second process kind, and no private
   protocol. The diagnostics arrive as text, which is what a compiler produces
   anyway, and the location header is regular enough to lift into fields.

   dune has no structured output for this. Its display modes are all human
   text, and `dune diagnostics`, which sounds like the answer, is an RPC client
   and answers "RPC server not running" without a watcher. Two flags below make
   the text less fragile to parse: messages separated by a blank line, and
   reported in a deterministic order rather than as discovered. *)

type diagnostic =
  { severity : string           (* error | warning *)
  ; file : string
  ; line : int
  ; col : int
  ; message : string
  }

type t =
  { success : bool
  ; diagnostics : diagnostic list
  ; output : string             (* everything dune said, unabridged *)
  }

let run_dune root targets =
  let cmd =
    Printf.sprintf
      "cd %s && %s build --display-separate-messages \
       --error-reporting=deterministic %s 2>&1"
      (Filename.quote root)
      (Filename.quote (Wire.Exe.find "dune"))
      (String.concat " " (List.map Filename.quote targets))
  in
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 4096 in
  (try
     while true do
       Buffer.add_channel buf ic 1
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  (Buffer.contents buf, status)

(* dune prefixes each problem with a location line:

     File "lib/x.ml", line 12, characters 17-29:

   and follows it with the offending source and the message. Splitting on that
   header recovers a diagnostic per problem with its position as data; the rest
   of the text is kept verbatim as the message, because a compiler diagnostic
   is prose and reformatting it would lose more than it gained. *)
let header = Str.regexp {|^File "\([^"]+\)", lines? \([0-9]+\)\(-[0-9]+\)?, characters? \([0-9]+\)|}

let severity_of block =
  if Str.string_match (Str.regexp_string "Error") (String.trim block) 0 then "error"
  else
    try ignore (Str.search_forward (Str.regexp "^Error") block 0); "error"
    with Not_found ->
      (try ignore (Str.search_forward (Str.regexp "^Warning") block 0); "warning"
       with Not_found -> "error")

let parse output =
  let lines = String.split_on_char '\n' output in
  (* group lines into blocks, each starting at a File "..." header *)
  let rec group acc current = function
    | [] -> List.rev (match current with None -> acc | Some c -> c :: acc)
    | line :: rest ->
      if Str.string_match header line 0 then
        let acc = match current with None -> acc | Some c -> c :: acc in
        group acc (Some (line, [])) rest
      else
        (match current with
         | None -> group acc None rest
         | Some (h, body) -> group acc (Some (h, line :: body)) rest)
  in
  List.filter_map
    (fun (h, body) ->
       if Str.string_match header h 0 then
         let file = Str.matched_group 1 h in
         let line = int_of_string (Str.matched_group 2 h) in
         let col = int_of_string (Str.matched_group 4 h) in
         (* Drop dune's echo of the source and its caret underline: they
            repeat the file the caller already has, and the position is
            already a field. What is left is the compiler's own words. *)
         (* Note the pipe is literal: in Str, "\\|" is alternation, and an
            empty right-hand branch matches every line. *)
         let numbered = Str.regexp "^ *[0-9]+ |" in
         let carets = Str.regexp "^ *\\^+ *$" in
         let is_echo l =
           Str.string_match numbered l 0 || Str.string_match carets l 0
         in
         let message =
           List.rev body
           |> List.filter (fun l -> not (is_echo l))
           |> String.concat "\n" |> String.trim
         in
         (* dune's own summary line is not a diagnostic *)
         if message = "" then None
         else Some { severity = severity_of message; file; line; col; message }
       else None)
    (group [] None lines)

let build root targets =
  if not (Sys.file_exists (Filename.concat root "dune-project")) then
    Error (root ^ " has no dune-project; it is not a dune project root")
  else
    let output, status = run_dune root targets in
    let success = status = Unix.WEXITED 0 in
    Ok { success; diagnostics = parse output; output = String.trim output }
