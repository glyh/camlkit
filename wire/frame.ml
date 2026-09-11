(* Frames are two length-prefixed segments:
     [4 bytes: len A][A: JSON metadata][4 bytes: len B][B: raw bytes]
   The payload is never escaped because it never enters JSON. Benchmarked
   against bin_prot, msgpck and cbor: all sit within noise of raw Buffer
   copying, while putting the payload inside JSON costs 24x encode and 87x
   decode at 10 MB. See docs/wayfinder/tickets/017. *)

type t = { meta : Yojson.Safe.t; payload : string }

exception Truncated

let put_u32 buf n =
  Buffer.add_char buf (Char.chr ((n lsr 24) land 0xff));
  Buffer.add_char buf (Char.chr ((n lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((n lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (n land 0xff))

let get_u32 ic =
  let b = Bytes.create 4 in
  (try really_input ic b 0 4 with End_of_file -> raise Truncated);
  let c i = Char.code (Bytes.get b i) in
  (c 0 lsl 24) lor (c 1 lsl 16) lor (c 2 lsl 8) lor c 3

let write oc { meta; payload } =
  let m = Yojson.Safe.to_string meta in
  let buf = Buffer.create (String.length m + String.length payload + 8) in
  put_u32 buf (String.length m);
  Buffer.add_string buf m;
  put_u32 buf (String.length payload);
  Buffer.add_string buf payload;
  Buffer.output_buffer oc buf;
  flush oc

(* None at a clean EOF; Truncated if a frame was cut mid-way. *)
let read ic =
  match get_u32 ic with
  | exception Truncated -> None
  | n ->
    let m = really_input_string ic n in
    let l = get_u32 ic in
    let payload = really_input_string ic l in
    Some { meta = Yojson.Safe.from_string m; payload }
