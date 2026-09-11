(* Functional core: frames as values. No I/O lives here.

   A frame is two length-prefixed segments:
     [4 bytes: len A][A: JSON metadata][4 bytes: len B][B: raw bytes]
   The payload never enters JSON, so it is never escaped. Benchmarked against
   bin_prot, msgpck and cbor: all sit within noise of raw Buffer copying,
   while putting the payload inside JSON costs 24x encode and 87x decode at
   10 MB. See docs/wayfinder/tickets/017. *)

type t = { meta : Yojson.Safe.t; payload : string }

(* What a reader should do next, given the bytes it has so far. Keeping this
   a value rather than a read loop is what makes the codec testable without
   a channel, a pipe or a temp file. *)
type parse =
  | Complete of t * int        (* frame, bytes consumed *)
  | Need of int                (* at least this many more bytes *)
  | Malformed of string

let u32_to_bytes buf n =
  Buffer.add_char buf (Char.chr ((n lsr 24) land 0xff));
  Buffer.add_char buf (Char.chr ((n lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((n lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (n land 0xff))

let u32_at s i =
  let c k = Char.code s.[i + k] in
  (c 0 lsl 24) lor (c 1 lsl 16) lor (c 2 lsl 8) lor c 3

let encode { meta; payload } =
  let m = Yojson.Safe.to_string meta in
  let buf = Buffer.create (String.length m + String.length payload + 8) in
  u32_to_bytes buf (String.length m);
  Buffer.add_string buf m;
  u32_to_bytes buf (String.length payload);
  Buffer.add_string buf payload;
  Buffer.contents buf

let parse s =
  let len = String.length s in
  if len < 4 then Need (4 - len)
  else
    let meta_len = u32_at s 0 in
    let after_meta = 4 + meta_len in
    if len < after_meta + 4 then Need (after_meta + 4 - len)
    else
      let payload_len = u32_at s after_meta in
      let total = after_meta + 4 + payload_len in
      if len < total then Need (total - len)
      else
        match Yojson.Safe.from_string (String.sub s 4 meta_len) with
        | meta -> Complete ({ meta; payload = String.sub s (after_meta + 4) payload_len },
                            total)
        | exception Yojson.Json_error m -> Malformed ("bad frame metadata: " ^ m)
