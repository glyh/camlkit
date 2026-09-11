(* The pieces of utop this worker actually used, over compiler-libs directly.

   utop was carrying twenty packages, including lambda-term, zed and lwt, for
   a handful of helpers, and its own toplevel hooks then had to be undone. What
   remained is here. Everything below is stable across the OCaml versions this
   supports; see docs/wayfinder for the check. *)

let input_name = "//toplevel//"

let to_string printer x =
  let b = Buffer.create 256 in
  let ppf = Format.formatter_of_buffer b in
  printer ppf x;
  Format.pp_print_flush ppf ();
  String.trim (Buffer.contents b)

(* Location keeps a count of lines already reported and separates later reports
   with a newline, which shifts anything reading this text. Reset per report. *)
let message_of_exn exn =
  Location.reset ();
  to_string (fun ppf e -> Errors.report_error ppf e) exn

(* Byte offsets come straight off the location, so unlike utop we do not
   recover them by scanning our own rendering of the error. *)
let spans_of_loc (loc : Location.t) =
  ( [ (loc.Location.loc_start.Lexing.pos_cnum,
       loc.Location.loc_end.Lexing.pos_cnum) ],
    [ (loc.Location.loc_start.Lexing.pos_lnum,
       loc.Location.loc_end.Lexing.pos_lnum) ] )

(* The location is already a field, so the message is rendered without its
   "Line N, characters A-B:" prefix rather than repeating it. *)
let render_msg (m : Location.msg) =
  to_string (fun ppf d -> Format_doc.Doc.format ppf d) m.Location.txt

(* message, byte spans, line ranges *)
let describe_exn exn =
  Location.reset ();
  match Location.error_of_exn exn with
  | Some (`Ok (err : Location.error)) ->
    let spans, lines = spans_of_loc err.Location.main.Location.loc in
    let body =
      String.concat "\n" (List.map render_msg (err.Location.main :: err.Location.sub))
    in
    ("Error: " ^ body, spans, lines)
  | _ -> (message_of_exn exn, [], [])

(* Parse a whole buffer into phrases.

   Incomplete input is a syntax error here, not a request for more. utop
   distinguishes them for a line editor that can prompt; nothing in this worker
   can, and letting utop's Need_more escape killed the session outright. *)
let parse src =
  let lexbuf = Lexing.from_string src in
  Location.init lexbuf input_name;
  Location.input_name := input_name;
  match !Toploop.parse_use_file lexbuf with
  | phrases -> Ok phrases
  | exception End_of_file -> Ok []
  | exception exn ->
    let message, spans, lines = describe_exn exn in
    Error (message, spans, lines)
