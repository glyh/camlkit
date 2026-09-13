(* Functional core: frames as values. No I/O lives here.

   A frame is a header and two length-prefixed segments:
     [4: magic][4: stamp][4: len A][A: metadata][4: len B][B: raw bytes]
   The payload is never encoded, so it is never escaped. Benchmarked against
   bin_prot, msgpck and cbor: all sit within noise of raw Buffer copying,
   while putting the payload inside JSON cost 24x encode and 87x decode at
   10 MB. See docs/wayfinder/tickets/017.

   The metadata is opaque here: Frame carries bytes and Msg decides what they
   mean. It is a Marshal of the request or response, see
   docs/wayfinder/tickets/043, which is why the header exists. Marshal casts
   blind, so a peer built from different source reads a pointer as an integer
   rather than failing, and the stamp is what turns that into a refusal. *)

(* Bumped by hand when the types in Msg change shape. The compiler version
   comes with it because bytecode is version-locked to it anyway, and a worker
   from another switch would otherwise read this one's frames.

   ponytail: a hand-bumped number, not a hash of the type definitions, which
   is not available at runtime. It catches a stale worker and a switch
   mismatch; it does not catch someone editing Msg and rebuilding one side
   without bumping it. *)
let format_version = 8

let magic = "CKF1"

let stamp =
  (* Hashtbl.hash is stable within a compiler version, which is all this has
     to be: both ends compute it at runtime and only equality matters. *)
  Hashtbl.hash (Sys.ocaml_version, format_version) land 0xffffffff

type t = { meta : string; payload : string }

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

let header_len = String.length magic + 4

let encode { meta; payload } =
  let buf =
    Buffer.create (String.length meta + String.length payload + header_len + 8) in
  Buffer.add_string buf magic;
  u32_to_bytes buf stamp;
  u32_to_bytes buf (String.length meta);
  Buffer.add_string buf meta;
  u32_to_bytes buf (String.length payload);
  Buffer.add_string buf payload;
  Buffer.contents buf

let parse s =
  let len = String.length s in
  if len < header_len then Need (header_len - len)
  else if String.sub s 0 (String.length magic) <> magic then
    Malformed "not a camlkit frame: wrong magic"
  else
    let theirs = u32_at s (String.length magic) in
    if theirs <> stamp then
      Malformed
        (Printf.sprintf
           "frame from an incompatible build (stamp %08x, expected %08x). The \
            server and worker must come from one build of one switch; check \
            CAMLKIT_WORKER and reinstall both."
           theirs stamp)
    else
      let meta_off = header_len + 4 in
      if len < meta_off then Need (meta_off - len)
      else
        let meta_len = u32_at s header_len in
        let after_meta = meta_off + meta_len in
        if len < after_meta + 4 then Need (after_meta + 4 - len)
        else
          let payload_len = u32_at s after_meta in
          let total = after_meta + 4 + payload_len in
          if len < total then Need (total - len)
          else
            Complete ({ meta = String.sub s meta_off meta_len;
                        payload = String.sub s (after_meta + 4) payload_len },
                      total)
